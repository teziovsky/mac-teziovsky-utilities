import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Checks that a compressed video is a complete, playable copy before its original is trashed.
enum CompressedVideoVerifier {
    enum Result: Equatable {
        case valid
        /// AVFoundation cannot read the format (e.g. MKV/WebM); the pair is processed with a note.
        case unverifiable(String)
        case invalid(String)
    }

    /// Allowed duration difference: HandBrake may trim a few frames, never seconds.
    static func durationTolerance(for originalSeconds: Double) -> Double {
        max(1, originalSeconds * 0.02)
    }

    static func verify(compressed: URL, original: URL) async -> Result {
        let supported = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
        guard let type = UTType(filenameExtension: compressed.pathExtension),
              supported.contains(type.identifier) else {
            return .unverifiable(
                "Not verified before deleting the original: AVFoundation cannot read "
                    + ".\(compressed.pathExtension) files."
            )
        }
        let asset = AVURLAsset(url: compressed)
        guard (try? await asset.load(.isPlayable)) == true,
              let duration = try? await asset.load(.duration),
              duration.isNumeric, duration.seconds > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            return .invalid("the compressed file is not a playable video (incomplete or corrupt encode?).")
        }
        let originalAsset = AVURLAsset(url: original)
        if let originalDuration = try? await originalAsset.load(.duration),
           originalDuration.isNumeric, originalDuration.seconds > 0 {
            let difference = abs(originalDuration.seconds - duration.seconds)
            if difference > durationTolerance(for: originalDuration.seconds) {
                let compressedText = String(format: "%.1f", duration.seconds)
                let originalText = String(format: "%.1f", originalDuration.seconds)
                return .invalid("the compressed file lasts \(compressedText) s but the original \(originalText) s.")
            }
        }
        return .valid
    }
}
