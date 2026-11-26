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
    /// The run was cancelled before the original was trashed; nothing changed.
    case cancelled
}

enum LocalMediaReplacementError: LocalizedError {
    case unreadableOriginal
    case undecodableImage
    case sizeMismatch(copy: (Int, Int), original: (Int, Int))
    case notPlayable
    case noDecodableFrame
    case durationMismatch
    case incompleteFile
    case incompleteVideo

    var errorDescription: String? {
        switch self {
        case .unreadableOriginal: return "Couldn't read the original"
        case .undecodableImage: return "The converted copy couldn't be decoded"
        case .sizeMismatch(let copy, let original):
            return "The converted copy is \(copy.0)×\(copy.1) pixels, the original is \(original.0)×\(original.1)"
        case .notPlayable: return "The converted copy isn't playable"
        case .noDecodableFrame: return "The converted copy's video doesn't decode"
        case .durationMismatch: return "The converted copy's duration doesn't match the original's"
        case .incompleteFile: return "The converted copy is incomplete"
        case .incompleteVideo: return "The converted copy's video doesn't decode to the end"
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
            if error is CancellationError || Task.isCancelled { return .cancelled }
            return .failed(error.localizedDescription)
        }
        // Verification can take seconds: look again right before anything changes.
        if let problem = Self.fileProblem(pair) { return .failed(problem) }
        if Task.isCancelled { return .cancelled }

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

    /// The copy's first image fully decodes, its file is complete, and it has the original's raw
    /// pixel size. Both sizes come from the stored pixel dimensions, so an EXIF orientation on
    /// either file doesn't matter.
    static func verifyImage(copy: URL, original: URL) throws {
        guard let originalSize = pixelSize(of: original) else {
            throw LocalMediaReplacementError.unreadableOriginal
        }
        let decodeNow = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(copy as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, decodeNow) != nil,
              let copySize = pixelSize(of: source) else {
            throw LocalMediaReplacementError.undecodableImage
        }
        // ImageIO decodes a cut-off JPEG or PNG without complaint (the missing part comes out
        // gray), so the file's own structure has to show that it is all there.
        guard let data = try? Data(contentsOf: copy, options: .mappedIfSafe),
              ImageFileCompleteness.isComplete(data, type: CGImageSourceGetType(source) as String?) else {
            throw LocalMediaReplacementError.incompleteFile
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
        // A file cut short whose movie header comes first still plays and reports its full
        // duration: only decoding a frame near the end shows the media data is all there.
        guard await decodesFrameNearTheEnd(copyAsset) else {
            throw LocalMediaReplacementError.incompleteVideo
        }
        // The last half second could still be cut off: the top-level boxes must fill the file exactly.
        guard MovieFileCompleteness.isComplete(copy) else {
            throw LocalMediaReplacementError.incompleteFile
        }
        guard let copyDuration = await readableDuration(of: copyAsset) else {
            throw LocalMediaReplacementError.incompleteVideo
        }
        // Many originals were converted precisely because AVFoundation can't read them (legacy
        // containers such as AVI or 3GP); some report no duration at all, or zero. Their copy was
        // already checked against them when it was made, so the duration is compared only when
        // the original's duration can be read.
        guard let originalDuration = await readableDuration(of: AVURLAsset(url: original)) else { return }
        guard LocalMediaRemuxVerifier.durationsMatch(copyDuration, source: originalDuration) else {
            throw LocalMediaReplacementError.durationMismatch
        }
    }

    /// Decodes the exact frame half a second before the video track ends (not the asset, whose
    /// audio may run longer). Zero tolerance matters: with any tolerance the generator may hand
    /// back an earlier keyframe from the intact part of the file.
    private static func decodesFrameNearTheEnd(_ asset: AVURLAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange),
              range.isValid, range.duration.isNumeric else { return false }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let nearEnd = CMTimeSubtract(CMTimeRangeGetEnd(range), CMTime(seconds: 0.5, preferredTimescale: 600))
        let time = CMTimeMaximum(range.start, nearEnd)
        return (try? await generator.image(at: time)) != nil
    }

    private static func readableDuration(of asset: AVURLAsset) async -> Double? {
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            return nil
        }
        return duration.seconds
    }
}

/// Whether an image file is whole, judged from its own structure. Only JPEG (what HEIC photos are
/// converted to) and PNG are checked; other formats count as complete once they decode.
enum ImageFileCompleteness {
    static func isComplete(_ data: Data, type: String?) -> Bool {
        switch type {
        case "public.jpeg": return jpegIsComplete(data)
        case "public.png": return pngIsComplete(data)
        default: return true
        }
    }

    /// Walks the JPEG segments from the start-of-image marker and requires the end-of-image
    /// marker after the last scan. Segment lengths skip embedded data such as an EXIF thumbnail,
    /// so its own end marker can't be mistaken for the file's.
    static func jpegIsComplete(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
            var index = 2
            while index < count {
                guard bytes[index] == 0xFF else { return false }
                while index < count, bytes[index] == 0xFF { index += 1 }
                guard index < count else { return false }
                let marker = bytes[index]
                index += 1
                if marker == 0xD9 { return true }
                if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
                guard let length = segmentLength(bytes, at: index) else { return false }
                index += length
                if marker == 0xDA {
                    guard let end = endOfScanData(bytes, from: index) else { return false }
                    index = end
                }
            }
            return false
        }
    }

    /// The big-endian segment length (which counts its own two bytes), or nil when it is cut off
    /// or impossible.
    private static func segmentLength(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int? {
        guard index + 1 < bytes.count else { return nil }
        let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        return length >= 2 ? length : nil
    }

    /// Entropy-coded data runs until a marker that is neither a stuffed 0xFF00 nor a restart (both
    /// may follow a run of 0xFF fill bytes); nil when the file ends first.
    private static func endOfScanData(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }
            var markerIndex = index + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < bytes.count else { return nil }
            let marker = bytes[markerIndex]
            if marker != 0x00, !(0xD0...0xD7).contains(marker) { return index }
            index = markerIndex + 1
        }
        return nil
    }

    /// A PNG ends with its IEND chunk: zero length, the type, and that chunk's fixed CRC.
    static func pngIsComplete(_ data: Data) -> Bool {
        let iend: [UInt8] = [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        return data.count >= 8 + iend.count && Array(data.suffix(iend.count)) == iend
    }
}

/// Whether an MP4 or QuickTime file is whole: its top-level boxes, each declaring its own size,
/// must add up to exactly the file's length. Other containers count as complete.
enum MovieFileCompleteness {
    private static let checkedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isComplete(_ url: URL) -> Bool {
        guard checkedExtensions.contains(url.pathExtension.lowercased()) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let fileLength = try? handle.seekToEnd() else { return false }
        var offset: UInt64 = 0
        while offset < fileLength {
            guard fileLength - offset >= 8,
                  (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8 else { return false }
            guard let length = boxLength(header, remaining: fileLength - offset) else { return false }
            offset += length
        }
        return offset == fileLength
    }

    /// The box's length from its header, or nil when it is impossible or runs past the file. A
    /// size of 0 means the box runs to the end; 1 means a 64-bit size follows the type.
    private static func boxLength(_ header: Data, remaining: UInt64) -> UInt64? {
        let length: UInt64
        switch UInt64(bigEndian: header.prefix(4)) {
        case 0:
            return remaining
        case 1:
            guard header.count == 16 else { return nil }
            length = UInt64(bigEndian: header.dropFirst(8))
            guard length >= 16 else { return nil }
        case let size:
            guard size >= 8 else { return nil }
            length = size
        }
        return length <= remaining ? length : nil
    }
}

private extension UInt64 {
    /// A big-endian unsigned integer from up to eight bytes.
    init<Bytes: Collection>(bigEndian bytes: Bytes) where Bytes.Element == UInt8 {
        self = bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
