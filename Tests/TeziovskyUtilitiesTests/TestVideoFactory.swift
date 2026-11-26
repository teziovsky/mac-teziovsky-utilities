import AVFoundation
import CoreVideo
import XCTest

/// Writes tiny real H.264 movies so tests exercise AVFoundation instead of fake bytes.
enum TestVideoFactory {
    static func makeVideo(
        at url: URL,
        seconds: Int,
        fileType: AVFileType = .mov,
        codec: AVVideoCodecType = .h264,
        metadata: [AVMetadataItem] = [],
        optimizeForNetworkUse: Bool = false,
        audioSeconds: Int? = nil
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.metadata = metadata
        // Puts the movie header before the media data, so a cut-off file still opens.
        writer.shouldOptimizeForNetworkUse = optimizeForNetworkUse
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        writer.add(input)
        // AAC silence, which may run longer than the video.
        let audio = audioSeconds.map { _ in makeAudioInput(format: kAudioFormatMPEG4AAC) }
        if let audio { writer.add(audio) }
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        if let audio, let audioSeconds {
            try await appendSilence(to: audio, seconds: audioSeconds)
        }

        let framesPerSecond: Int32 = 10
        for frame in 0...(Int32(seconds) * framesPerSecond) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let buffer = try makeFrame(adaptor: adaptor, shade: UInt8(truncatingIfNeeded: frame * 9))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// An HEVC movie whose sample entry is tagged `hev1` (as Android phones record it), which
    /// AVFoundation can demux but not decode. Optionally adds a 16-bit PCM audio track.
    static func makeHEV1Video(at url: URL, seconds: Int, fileType: AVFileType, pcmAudio: Bool = false) async throws {
        let hvc1 = url.deletingLastPathComponent()
            .appendingPathComponent("hvc1-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: hvc1) }
        try await makeVideo(at: hvc1, seconds: seconds, fileType: .mov, codec: .hevc)

        let asset = AVURLAsset(url: hvc1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let source = try XCTUnwrap(descriptions.first)
        let extensions = NSMutableDictionary(
            dictionary: CMFormatDescriptionGetExtensions(source) ?? [:] as CFDictionary
        )
        extensions.removeObject(forKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry)
        extensions.removeObject(forKey: kCMFormatDescriptionExtension_VerbatimSampleDescription)
        extensions.removeObject(forKey: kCMFormatDescriptionExtension_FormatName)
        let dimensions = CMVideoFormatDescriptionGetDimensions(source)
        var hev1: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: FourCharCode(0x6865_7631), // 'hev1'
            width: dimensions.width,
            height: dimensions.height,
            extensions: extensions,
            formatDescriptionOut: &hev1
        )
        let description = try XCTUnwrap(hev1)

        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let audio = pcmAudio ? makeAudioInput(format: kAudioFormatLinearPCM) : nil
        if let audio { writer.add(audio) }
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            input.append(try retagged(sample, as: description))
        }
        input.markAsFinished()
        if let audio {
            try await appendSilence(to: audio, seconds: seconds)
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private static func retagged(_ sample: CMSampleBuffer, as description: CMFormatDescription) throws -> CMSampleBuffer {
        var timing = try sample.sampleTimingInfos()
        var sizes = (try? sample.sampleSizes()) ?? []
        var copy: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: sample.dataBuffer,
            formatDescription: description,
            sampleCount: sample.numSamples,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: sizes.count,
            sampleSizeArray: &sizes,
            sampleBufferOut: &copy
        )
        let result = try XCTUnwrap(copy)
        // Keep "not a sync sample" flags, as a real recording has them; without them every frame
        // counts as a keyframe and decoding from any point but the start fails.
        if let source = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary],
           let target = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) {
            for (index, attachments) in source.enumerated() where index < CFArrayGetCount(target) {
                let entry = unsafeBitCast(CFArrayGetValueAtIndex(target, index), to: NSMutableDictionary.self)
                entry.addEntries(from: attachments as? [AnyHashable: Any] ?? [:])
            }
        }
        return result
    }

    private static func makeAudioInput(format: AudioFormatID) -> AVAssetWriterInput {
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1]
        if format == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private static func appendSilence(to input: AVAssetWriterInput, seconds: Int) async throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        let frames = 8000 * seconds
        let bytes = frames * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
        )
        let data = try XCTUnwrap(block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: try XCTUnwrap(format),
            sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample
        )
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        input.append(try XCTUnwrap(sample))
        input.markAsFinished()
    }

    static func creationDateItem(_ date: Date) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
        item.value = ISO8601DateFormatter().string(from: date) as NSString
        return item
    }

    static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.value = identifier as NSString
        return item
    }

    private static func makeFrame(adaptor: AVAssetWriterInputPixelBufferAdaptor, shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(shade), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
