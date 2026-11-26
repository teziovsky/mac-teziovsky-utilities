import AVFoundation
import Foundation

/// Rewraps HEVC tagged `hev1` (how many Android phones record it) as `hvc1` without re-encoding.
///
/// AVFoundation demuxes `hev1` but refuses to decode or export it ("Operation Stopped",
/// AVError -11838). The parameter sets live in the `hvcC` atom either way, so copying the
/// compressed samples under an `hvc1` sample entry is enough for macOS to play the file.
enum HEVCRetagger {
    /// The `hev1` FourCC: HEVC whose parameter sets may also appear in-band.
    static let hev1CodecType: FourCharCode = 0x6865_7631

    static func rewrap(_ sourceURL: URL, to destinationURL: URL, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = fileType == .mp4
        writer.metadata = await metadataKeepingCaptureDate(of: asset)

        var pumps: [SamplePump] = []
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            let description = try await track.load(.formatDescriptions).first
            let replacement = description.flatMap(hvc1Description(replacing:))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw LocalMediaConversionError.unsupportedOutput }
            reader.add(output)
            let input = AVAssetWriterInput(
                mediaType: track.mediaType,
                outputSettings: nil,
                sourceFormatHint: replacement ?? description
            )
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                input.transform = try await track.load(.preferredTransform)
            }
            guard writer.canAdd(input) else { throw LocalMediaConversionError.unsupportedOutput }
            writer.add(input)
            pumps.append(SamplePump(output: output, input: input, replacement: replacement))
        }

        guard reader.startReading() else {
            throw reader.error ?? LocalMediaConversionError.exportUnavailable
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? LocalMediaConversionError.exportUnavailable
        }
        writer.startSession(atSourceTime: .zero)

        let cancellation = RewrapCancellation(reader: reader)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pump in pumps {
                    group.addTask { await pump.run() }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        if Task.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }

        if reader.status == .failed || pumps.contains(where: \.failed) {
            writer.cancelWriting()
            throw LocalMediaConversionError.exportFailed(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription
                    ?? "The video streams could not be copied."
            )
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LocalMediaConversionError.exportFailed(
                writer.error?.localizedDescription ?? "The rewrapped video could not be written."
            )
        }
    }

    /// Android stores the capture time only in the movie header, which the new file would reset
    /// to now; carry it over as a QuickTime creation-date item.
    private static func metadataKeepingCaptureDate(of asset: AVAsset) async -> [AVMetadataItem] {
        var metadata = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        guard !common.contains(where: { $0.commonKey == .commonKeyCreationDate }),
              let captured = try? await asset.load(.creationDate)?.load(.dateValue) else {
            return metadata
        }
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
        item.value = VideoMetadataTransfer.creationDateString(for: captured, matching: nil) as NSString
        metadata.append(item)
        return metadata
    }

    /// The same stream description with the `hvc1` codec type. The verbatim sample entry is
    /// dropped so the writer builds a fresh `hvc1` entry instead of copying the `hev1` one.
    private static func hvc1Description(replacing description: CMFormatDescription) -> CMFormatDescription? {
        guard CMFormatDescriptionGetMediaSubType(description) == hev1CodecType else { return nil }
        let extensions = NSMutableDictionary(
            dictionary: (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
        )
        extensions.removeObject(forKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry)
        extensions.removeObject(forKey: kCMFormatDescriptionExtension_VerbatimSampleDescription)
        extensions.removeObject(forKey: kCMFormatDescriptionExtension_FormatName)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        var result: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: kCMVideoCodecType_HEVC,
            width: dimensions.width,
            height: dimensions.height,
            extensions: extensions,
            formatDescriptionOut: &result
        )
        return status == noErr ? result : nil
    }
}

/// Moves one track's compressed samples from the reader to the writer.
private final class SamplePump: @unchecked Sendable {
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let replacement: CMFormatDescription?
    private let queue = DispatchQueue(label: "com.teziovsky.utilities.hevc-rewrap")
    private(set) var failed = false

    init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, replacement: CMFormatDescription?) {
        self.output = output
        self.input = input
        self.replacement = replacement
    }

    /// Touched only on `queue`.
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in pump() }
            }
        }
    }

    private func pump() {
        while continuation != nil, input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                finish()
                return
            }
            guard let retagged = retag(sample), input.append(retagged) else {
                failed = true
                finish()
                return
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        input.markAsFinished()
        continuation.resume()
    }

    private func retag(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let replacement else { return sample }
        guard var timing = try? sample.sampleTimingInfos() else { return nil }
        var sizes = (try? sample.sampleSizes()) ?? []
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: sample.dataBuffer,
            formatDescription: replacement,
            sampleCount: sample.numSamples,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: sizes.count,
            sampleSizeArray: &sizes,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return nil }
        copySampleAttachments(from: sample, to: copy)
        return copy
    }

    /// Keeps per-sample flags such as "not a sync sample" so keyframes stay marked.
    private func copySampleAttachments(from source: CMSampleBuffer, to target: CMSampleBuffer) {
        guard let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false)
                as? [NSDictionary],
              let targetAttachments = CMSampleBufferGetSampleAttachmentsArray(target, createIfNecessary: true)
        else { return }
        for (index, attachments) in sourceAttachments.enumerated()
        where index < CFArrayGetCount(targetAttachments) {
            let destination = unsafeBitCast(
                CFArrayGetValueAtIndex(targetAttachments, index),
                to: NSMutableDictionary.self
            )
            destination.addEntries(from: attachments as? [AnyHashable: Any] ?? [:])
        }
    }
}

private final class RewrapCancellation: @unchecked Sendable {
    private let reader: AVAssetReader

    init(reader: AVAssetReader) {
        self.reader = reader
    }

    /// Stops reading; each pump then sees the end of its track and finishes on its own.
    func cancel() {
        reader.cancelReading()
    }
}
