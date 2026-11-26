import AVFoundation
import Darwin
import Foundation
import ImageIO

enum LocalMediaReplacementOutcome: Equatable, Sendable {
    /// The original is in the Trash and the copy has its final name.
    case replaced
    /// The original is in the Trash, but the copy could not take its final name.
    case replacedKeptCopyName(String)
    /// Nothing was trashed or renamed.
    case failed(String)
}

enum LocalMediaReplacementError: LocalizedError {
    case unreadableOriginal
    case undecodableImage
    case sizeMismatch(copy: (Int, Int), original: (Int, Int))
    case notPlayable
    case noDecodableFrame
    case durationMismatch

    var errorDescription: String? {
        switch self {
        case .unreadableOriginal: return "Couldn't read the original"
        case .undecodableImage: return "The converted copy couldn't be decoded"
        case .sizeMismatch(let copy, let original):
            return "The converted copy is \(copy.0)×\(copy.1) pixels, the original is \(original.0)×\(original.1)"
        case .notPlayable: return "The converted copy isn't playable"
        case .noDecodableFrame: return "The converted copy's video doesn't decode"
        case .durationMismatch: return "The converted copy's duration doesn't match the original's"
        }
    }
}

/// Replaces an original with its converted copy: verify the copy, move the original to the
/// Trash, then give the copy the original's name. Nothing is ever deleted permanently and the
/// rename never replaces an existing file.
struct LocalMediaReplacer {
    typealias Trash = @Sendable (URL) throws -> Void
    typealias Verify = @Sendable (LocalMediaReplaceablePair) async throws -> Void

    private let trash: Trash
    private let verify: Verify

    init(
        trash: @escaping Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        verify: @escaping Verify = { try await LocalMediaReplacer.defaultVerify($0) }
    ) {
        self.trash = trash
        self.verify = verify
    }

    func replace(_ pair: LocalMediaReplaceablePair) async -> LocalMediaReplacementOutcome {
        if let problem = Self.fileProblem(pair) { return .failed(problem) }
        do {
            try await verify(pair)
        } catch {
            return .failed(error.localizedDescription)
        }
        // Verification can take seconds: look again right before anything changes.
        if let problem = Self.fileProblem(pair) { return .failed(problem) }
        if Task.isCancelled { return .failed("Cancelled") }

        do {
            try trash(pair.originalURL)
        } catch {
            return .failed("Couldn't move the original to the Trash: \(error.localizedDescription)")
        }

        let copyName = pair.copyURL.lastPathComponent
        guard pair.finalName != copyName else { return .replaced }
        let target = pair.copyURL.deletingLastPathComponent().appendingPathComponent(pair.finalName)
        guard let error = ExternalDriveMoverFileSystem.renameWithoutReplacing(from: pair.copyURL, to: target) else {
            return .replaced
        }
        if error.code == .EEXIST {
            return .replacedKeptCopyName(
                "Original trashed; copy kept as \(copyName) because \(pair.finalName) exists"
            )
        }
        return .replacedKeptCopyName(
            "Original trashed; copy kept as \(copyName) because renaming it to \(pair.finalName) failed: "
                + error.localizedDescription
        )
    }

    /// Why the pair can't be replaced right now, or nil when both files are still in place.
    private static func fileProblem(_ pair: LocalMediaReplaceablePair) -> String? {
        var original = stat()
        var copy = stat()
        guard lstat(pair.originalURL.path, &original) == 0, (original.st_mode & S_IFMT) == S_IFREG else {
            return "Original no longer exists"
        }
        guard lstat(pair.copyURL.path, &copy) == 0, (copy.st_mode & S_IFMT) == S_IFREG else {
            return "Converted copy no longer exists"
        }
        // Two names for one file: trashing the "original" would take the copy with it.
        if original.st_dev == copy.st_dev, original.st_ino == copy.st_ino {
            return "The converted copy is the original file"
        }
        return nil
    }

    // MARK: - Verification

    @Sendable
    static func defaultVerify(_ pair: LocalMediaReplaceablePair) async throws {
        if pair.isVideo {
            try await verifyVideo(copy: pair.copyURL, original: pair.originalURL)
        } else {
            try verifyImage(copy: pair.copyURL, original: pair.originalURL)
        }
    }

    /// The copy's first image decodes and has the original's raw pixel size. Both sizes come from
    /// the stored pixel dimensions, so an EXIF orientation on either file doesn't matter.
    static func verifyImage(copy: URL, original: URL) throws {
        guard let originalSize = pixelSize(of: original) else {
            throw LocalMediaReplacementError.unreadableOriginal
        }
        guard let source = CGImageSourceCreateWithURL(copy as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let copySize = pixelSize(of: source) else {
            throw LocalMediaReplacementError.undecodableImage
        }
        guard copySize == originalSize else {
            throw LocalMediaReplacementError.sizeMismatch(copy: copySize, original: originalSize)
        }
    }

    private static func pixelSize(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> (Int, Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The copy plays, a frame of its video really decodes, and its duration is within the
    /// conversion's tolerance of the original's.
    static func verifyVideo(copy: URL, original: URL) async throws {
        let copyAsset = AVURLAsset(url: copy)
        guard (try? await copyAsset.load(.isPlayable)) == true else {
            throw LocalMediaReplacementError.notPlayable
        }
        guard await LocalMediaRemuxVerifier.decodesAFrame(copyAsset) else {
            throw LocalMediaReplacementError.noDecodableFrame
        }
        // Many originals were converted precisely because AVFoundation can't read them (legacy
        // containers such as AVI or 3GP); some report no duration at all, or zero. Their copy was
        // already checked against them when it was made, so the duration is compared only when
        // the original's duration can be read.
        guard let originalDuration = await readableDuration(of: AVURLAsset(url: original)) else { return }
        guard let copyDuration = await readableDuration(of: copyAsset),
              LocalMediaRemuxVerifier.durationsMatch(copyDuration, source: originalDuration) else {
            throw LocalMediaReplacementError.durationMismatch
        }
    }

    private static func readableDuration(of asset: AVURLAsset) async -> Double? {
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            return nil
        }
        return duration.seconds
    }
}
