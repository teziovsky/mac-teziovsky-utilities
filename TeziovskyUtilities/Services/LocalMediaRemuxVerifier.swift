import AVFoundation
import CoreMedia
import Foundation

/// Checks a video rewrapped without re-encoding before its original may go.
enum LocalMediaRemuxVerifier {
    typealias DecodeCheck = @Sendable (AVURLAsset) async -> Bool

    /// A rewrapped file must play, decode, and keep the source's video codec (`hev1` → `hvc1`) and duration.
    static func verify(_ url: URL, source: URL, decodes: DecodeCheck = { await decodesAFrame($0) }) async throws {
        let output = AVURLAsset(url: url)
        let original = AVURLAsset(url: source)
        guard try await output.load(.isPlayable),
              let outputCodec = try await videoSubtype(of: output),
              var sourceCodec = try await videoSubtype(of: original) else {
            throw LocalMediaConversionError.verificationFailed
        }
        if sourceCodec == HEVCRetagger.hev1CodecType { sourceCodec = kCMVideoCodecType_HEVC }
        guard outputCodec == sourceCodec, await decodes(output) else {
            throw LocalMediaConversionError.verificationFailed
        }
        let outputDuration = try await output.load(.duration).seconds
        let sourceDuration = try await original.load(.duration).seconds
        guard durationsMatch(outputDuration, source: sourceDuration) else {
            throw LocalMediaConversionError.verificationFailed
        }
    }

    /// The conversion's tolerance: half a second or 1% of the source, whichever is larger.
    static func durationsMatch(_ output: Double, source: Double) -> Bool {
        abs(output - source) <= max(0.5, source * 0.01)
    }

    static func videoSubtype(of asset: AVAsset) async throws -> FourCharCode? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await track.load(.formatDescriptions).first else { return nil }
        return CMFormatDescriptionGetMediaSubType(description)
    }

    /// The video track says it can be decoded, and one frame (10% in) really decodes.
    static func decodesAFrame(_ asset: AVURLAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              (try? await track.load(.isDecodable)) == true else { return false }
        let duration = (try? await asset.load(.duration)) ?? .zero
        let time = duration.isNumeric && duration.seconds > 0
            ? CMTimeMultiplyByFloat64(duration, multiplier: 0.1) : .zero
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return (try? await generator.image(at: time)) != nil
    }
}
