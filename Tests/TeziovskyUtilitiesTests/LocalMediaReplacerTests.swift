import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TeziovskyUtilities

/// Moves files into a folder instead of the real Trash and remembers what it moved.
private final class FakeTrash: @unchecked Sendable {
    let folder: URL
    var failure: Error?
    private let lock = NSLock()
    private var items: [String] = []

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var trashedNames: [String] { lock.withLock { items } }

    func trash(_ url: URL) throws {
        if let failure { throw failure }
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        lock.withLock { items.append(url.lastPathComponent) }
    }
}

private struct VerifyFailure: LocalizedError {
    var errorDescription: String? { "The copy is broken" }
}

final class LocalMediaReplacerTests: XCTestCase {
    private var root: URL!
    private var trash: FakeTrash!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMediaReplacerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trash = try FakeTrash(folder: root.appendingPathComponent(".trash", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ name: String, bytes: [UInt8] = [1, 2, 3]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private var miaPair: LocalMediaReplaceablePair {
        pair("Mia.mp4", "Mia-converted.mp4", finalName: "Mia.mp4")
    }

    private func pair(
        _ original: String,
        _ copy: String,
        finalName: String,
        isVideo: Bool = true
    ) -> LocalMediaReplaceablePair {
        LocalMediaReplaceablePair(
            originalURL: root.appendingPathComponent(original),
            originalRelativePath: original,
            copyURL: root.appendingPathComponent(copy),
            copyRelativePath: copy,
            finalName: finalName,
            isVideo: isVideo
        )
    }

    private func replacer(verify: @escaping @Sendable (LocalMediaReplaceablePair) async throws -> Void = { _ in })
        -> LocalMediaReplacer {
        let trash = trash!
        return LocalMediaReplacer(trash: { try trash.trash($0) }, verify: verify)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func contents(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent(name)))
    }

    func testVideoCopyTakesTheOriginalName() async throws {
        _ = try write("Mia_32.mp4", bytes: [1])
        _ = try write("Mia_32-converted.mp4", bytes: [2])

        let outcome = await replacer().replace(pair("Mia_32.mp4", "Mia_32-converted.mp4", finalName: "Mia_32.mp4"))

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(trash.trashedNames, ["Mia_32.mp4"])
        XCTAssertEqual(try contents("Mia_32.mp4"), [2])
        XCTAssertFalse(exists("Mia_32-converted.mp4"))
    }

    func testHEICCopyKeepsItsJPGName() async throws {
        _ = try write("IMG.heic", bytes: [1])
        _ = try write("IMG.jpg", bytes: [2])

        let outcome = await replacer().replace(pair("IMG.heic", "IMG.jpg", finalName: "IMG.jpg", isVideo: false))

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(trash.trashedNames, ["IMG.heic"])
        XCTAssertEqual(try contents("IMG.jpg"), [2])
        XCTAssertFalse(exists("IMG.heic"))
    }

    func testRenameNeverOverwrites() async throws {
        _ = try write("Clip.avi", bytes: [1])
        _ = try write("Clip (1).mp4", bytes: [2])
        _ = try write("Clip.mp4", bytes: [9])

        let outcome = await replacer().replace(pair("Clip.avi", "Clip (1).mp4", finalName: "Clip.mp4", isVideo: true))

        XCTAssertEqual(
            outcome,
            .replacedKeptCopyName("Original trashed; copy kept as Clip (1).mp4 because Clip.mp4 exists")
        )
        XCTAssertEqual(trash.trashedNames, ["Clip.avi"])
        XCTAssertEqual(try contents("Clip.mp4"), [9])
        XCTAssertEqual(try contents("Clip (1).mp4"), [2])
    }

    func testFailedVerificationKeepsOriginal() async throws {
        _ = try write("Mia.mp4", bytes: [1])
        _ = try write("Mia-converted.mp4", bytes: [2])

        let outcome = await replacer(verify: { _ in throw VerifyFailure() })
            .replace(miaPair)

        XCTAssertEqual(outcome, .failed("The copy is broken"))
        XCTAssertTrue(trash.trashedNames.isEmpty)
        XCTAssertEqual(try contents("Mia.mp4"), [1])
        XCTAssertEqual(try contents("Mia-converted.mp4"), [2])
    }

    func testOriginalGoneAtApplyFails() async throws {
        _ = try write("Mia-converted.mp4", bytes: [2])

        let outcome = await replacer().replace(miaPair)

        XCTAssertEqual(outcome, .failed("Original no longer exists"))
        XCTAssertTrue(trash.trashedNames.isEmpty)
        XCTAssertEqual(try contents("Mia-converted.mp4"), [2])
    }

    func testOriginalGoneDuringVerificationFails() async throws {
        let original = try write("Mia.mp4", bytes: [1])
        _ = try write("Mia-converted.mp4", bytes: [2])

        let outcome = await replacer(verify: { _ in try FileManager.default.removeItem(at: original) })
            .replace(miaPair)

        XCTAssertEqual(outcome, .failed("Original no longer exists"))
        XCTAssertTrue(trash.trashedNames.isEmpty)
        XCTAssertEqual(try contents("Mia-converted.mp4"), [2])
    }

    func testCopyGoneFails() async throws {
        _ = try write("Mia.mp4", bytes: [1])

        let outcome = await replacer().replace(miaPair)

        XCTAssertEqual(outcome, .failed("Converted copy no longer exists"))
        XCTAssertTrue(trash.trashedNames.isEmpty)
        XCTAssertEqual(try contents("Mia.mp4"), [1])
    }

    func testCopyGoneDuringVerificationFails() async throws {
        _ = try write("Mia.mp4", bytes: [1])
        let copy = try write("Mia-converted.mp4", bytes: [2])

        let outcome = await replacer(verify: { _ in try FileManager.default.removeItem(at: copy) })
            .replace(miaPair)

        XCTAssertEqual(outcome, .failed("Converted copy no longer exists"))
        XCTAssertTrue(trash.trashedNames.isEmpty)
        XCTAssertEqual(try contents("Mia.mp4"), [1])
    }

    func testCopyThatIsASymlinkFails() async throws {
        _ = try write("Mia.mp4", bytes: [1])
        _ = try write("Other.mp4", bytes: [2])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Mia-converted.mp4"),
            withDestinationURL: root.appendingPathComponent("Other.mp4")
        )

        let outcome = await replacer().replace(miaPair)

        XCTAssertEqual(outcome, .failed("Converted copy no longer exists"))
        XCTAssertTrue(trash.trashedNames.isEmpty)
    }

    func testCopyThatIsTheOriginalFails() async throws {
        let original = try write("Mia.mp4", bytes: [1])
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("Mia-converted.mp4"))

        let outcome = await replacer().replace(miaPair)

        XCTAssertEqual(outcome, .failed("The converted copy is the original file"))
        XCTAssertTrue(trash.trashedNames.isEmpty)
    }

    func testTrashFailureKeepsCopyName() async throws {
        _ = try write("Mia.mp4", bytes: [1])
        _ = try write("Mia-converted.mp4", bytes: [2])
        trash.failure = CocoaError(.fileWriteNoPermission)

        let outcome = await replacer().replace(miaPair)

        guard case .failed(let message) = outcome else { return XCTFail("Expected a failure, got \(outcome)") }
        XCTAssertTrue(message.hasPrefix("Couldn't move the original to the Trash"), message)
        XCTAssertTrue(trash.trashedNames.isEmpty)
        XCTAssertEqual(try contents("Mia.mp4"), [1])
        XCTAssertEqual(try contents("Mia-converted.mp4"), [2])
    }

    func testCancelledDuringVerificationTrashesNothing() async throws {
        _ = try write("Mia.mp4", bytes: [1])
        _ = try write("Mia-converted.mp4", bytes: [2])

        let outcome = await replacer(verify: { _ in withUnsafeCurrentTask { $0?.cancel() } }).replace(miaPair)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(trash.trashedNames.isEmpty)
        XCTAssertEqual(try contents("Mia.mp4"), [1])
        XCTAssertEqual(try contents("Mia-converted.mp4"), [2])
    }
}

/// The real verification run before an original goes to the Trash.
final class LocalMediaReplacerVerifyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMediaReplacerVerifyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeImage(_ name: String, width: Int, height: Int, type: UTType) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // A busy pattern, so a JPEG's compressed data is most of the file.
        for index in 0..<200 {
            context.setFillColor(
                red: CGFloat(index % 7) / 7, green: CGFloat(index % 5) / 5, blue: CGFloat(index % 3) / 3, alpha: 1
            )
            context.fill(CGRect(x: (index * 37) % width, y: (index * 53) % height, width: 9, height: 7))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pair(_ original: URL, _ copy: URL, isVideo: Bool) -> LocalMediaReplaceablePair {
        LocalMediaReplaceablePair(
            originalURL: original,
            originalRelativePath: original.lastPathComponent,
            copyURL: copy,
            copyRelativePath: copy.lastPathComponent,
            finalName: original.deletingPathExtension().lastPathComponent + "." + copy.pathExtension,
            isVideo: isVideo
        )
    }

    private func verifyError(_ pair: LocalMediaReplaceablePair) async -> String? {
        do {
            try await LocalMediaReplacer.defaultVerify(pair)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testImageWithTheSameSizePasses() async throws {
        let original = try writeImage("IMG.png", width: 8, height: 6, type: .png)
        let copy = try writeImage("IMG.jpg", width: 8, height: 6, type: .jpeg)

        let error = await verifyError(pair(original, copy, isVideo: false))
        XCTAssertNil(error)
    }

    func testImageWithADifferentSizeFails() async throws {
        let original = try writeImage("IMG.png", width: 8, height: 6, type: .png)
        let copy = try writeImage("IMG.jpg", width: 6, height: 8, type: .jpeg)

        let error = await verifyError(pair(original, copy, isVideo: false))
        XCTAssertEqual(error, "The converted copy is 6×8 pixels, the original is 8×6")
    }

    func testUndecodableImageCopyFails() async throws {
        let original = try writeImage("IMG.png", width: 8, height: 6, type: .png)
        let copy = root.appendingPathComponent("IMG.jpg")
        try Data([1, 2, 3]).write(to: copy)

        let error = await verifyError(pair(original, copy, isVideo: false))
        XCTAssertEqual(error, "The converted copy couldn't be decoded")
    }

    func testUnreadableImageOriginalFails() async throws {
        let original = root.appendingPathComponent("IMG.heic")
        try Data([1, 2, 3]).write(to: original)
        let copy = try writeImage("IMG.jpg", width: 8, height: 6, type: .jpeg)

        let error = await verifyError(pair(original, copy, isVideo: false))
        XCTAssertEqual(error, "Couldn't read the original")
    }

    func testVideoWithTheSameDurationPasses() async throws {
        let original = root.appendingPathComponent("Clip.mov")
        let copy = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeVideo(at: original, seconds: 2)
        try await TestVideoFactory.makeVideo(at: copy, seconds: 2, fileType: .mp4)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertNil(error)
    }

    func testVideoWithADifferentDurationFails() async throws {
        let original = root.appendingPathComponent("Clip.mov")
        let copy = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeVideo(at: original, seconds: 2)
        try await TestVideoFactory.makeVideo(at: copy, seconds: 5, fileType: .mp4)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertEqual(error, "The converted copy's duration doesn't match the original's")
    }

    func testVideoWithAnUnreadableOriginalChecksOnlyTheCopy() async throws {
        let original = root.appendingPathComponent("Clip.avi")
        try Data([1, 2, 3]).write(to: original)
        let copy = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeVideo(at: copy, seconds: 2, fileType: .mp4)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertNil(error)
    }

    func testHEV1VideoCopyFails() async throws {
        let original = root.appendingPathComponent("Clip.mov")
        try await TestVideoFactory.makeVideo(at: original, seconds: 1)
        let copy = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeHEV1Video(at: copy, seconds: 1, fileType: .mp4)

        let error = await verifyError(pair(original, copy, isVideo: true))
        // AVFoundation reports a `hev1` movie as not playable, so the first check catches it.
        XCTAssertEqual(error, "The converted copy isn't playable")
    }

    func testTruncatedVideoCopyFails() async throws {
        let original = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeVideo(at: original, seconds: 4, fileType: .mp4, optimizeForNetworkUse: true)
        let data = try Data(contentsOf: original)
        let moov = try XCTUnwrap(data.range(of: Data("moov".utf8)))
        let mdat = try XCTUnwrap(data.range(of: Data("mdat".utf8)))
        XCTAssertLessThan(moov.lowerBound, mdat.lowerBound, "the movie header must come first")
        let copy = root.appendingPathComponent("Clip-converted.mp4")
        try data.prefix(data.count * 6 / 10).write(to: copy)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertEqual(error, "The converted copy's video doesn't decode to the end")
    }

    func testTruncatedJPEGCopyFails() async throws {
        let original = try writeImage("IMG.png", width: 64, height: 48, type: .png)
        let full = try writeImage("Full.jpg", width: 64, height: 48, type: .jpeg)
        let data = try Data(contentsOf: full)
        for fraction in [5, 9] {
            let copy = root.appendingPathComponent("IMG-\(fraction).jpg")
            try data.prefix(data.count * fraction / 10).write(to: copy)

            let error = await verifyError(pair(original, copy, isVideo: false))
            XCTAssertEqual(error, "The converted copy is incomplete", "cut to \(fraction)0%")
        }
        let error = await verifyError(pair(original, full, isVideo: false))
        XCTAssertNil(error)
    }

    func testBrokenVideoCopyFails() async throws {
        let original = root.appendingPathComponent("Clip.mov")
        try await TestVideoFactory.makeVideo(at: original, seconds: 1)
        let copy = root.appendingPathComponent("Clip.mp4")
        try Data([1, 2, 3]).write(to: copy)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertEqual(error, "The converted copy isn't playable")
    }

    func testVideoWithAudioRunningPastItsVideoPasses() async throws {
        let original = root.appendingPathComponent("Clip.mov")
        try await TestVideoFactory.makeVideo(at: original, seconds: 1, audioSeconds: 3)
        let copy = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeVideo(
            at: copy, seconds: 1, fileType: .mp4, optimizeForNetworkUse: true, audioSeconds: 3
        )

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertNil(error)
    }

    func testVideoCopyCutInItsLastBytesFails() async throws {
        let original = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeVideo(at: original, seconds: 4, fileType: .mp4, optimizeForNetworkUse: true)
        let data = try Data(contentsOf: original)
        let copy = root.appendingPathComponent("Clip-converted.mp4")
        try data.prefix(data.count * 95 / 100).write(to: copy)
        let cutError = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertNotNil(cutError, "cut to 95%")
        // Only the last frame's bytes missing: the frame half a second before the end still
        // decodes, so the box sizes are what catches it.
        try data.prefix(data.count - 16).write(to: copy)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertEqual(error, "The converted copy is incomplete")
        let intactError = await verifyError(pair(copy, original, isVideo: true))
        XCTAssertNil(intactError)
    }
}

final class ImageFileCompletenessTests: XCTestCase {
    /// SOI, a minimal scan header, scan data, then EOI.
    private func jpeg(scanData: [UInt8]) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02] + scanData + [0xFF, 0xD9])
    }

    func testRestartMarkerAfterFillBytesStaysInsideTheScan() {
        XCTAssertTrue(ImageFileCompleteness.jpegIsComplete(jpeg(scanData: [0x12, 0xFF, 0xFF, 0xD0, 0x34])))
        XCTAssertTrue(ImageFileCompleteness.jpegIsComplete(jpeg(scanData: [0x12, 0xFF, 0x00, 0xFF, 0xD7, 0x34])))
    }

    func testFillBytesBeforeTheEndMarkerAreAccepted() {
        let scanStart: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x12]
        XCTAssertTrue(ImageFileCompleteness.jpegIsComplete(Data(scanStart + [0xFF, 0xFF, 0xD9])))
    }

    func testScanCutOffIsIncomplete() {
        let scanStart: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x12]
        XCTAssertFalse(ImageFileCompleteness.jpegIsComplete(Data(scanStart + [0xFF, 0xFF, 0xD0])))
        XCTAssertFalse(ImageFileCompleteness.jpegIsComplete(Data(scanStart + [0x34])))
    }
}

final class MovieFileCompletenessTests: XCTestCase {
    private func isComplete(_ bytes: [UInt8]) throws -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Boxes-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes).write(to: url)
        return MovieFileCompleteness.isComplete(url)
    }

    private let ftyp: [UInt8] = [0, 0, 0, 12] + Array("ftyp".utf8) + [1, 2, 3, 4]
    /// A box with a 64-bit size of 24: size field 1, type, largesize, then 8 bytes of payload.
    private let largeMdat: [UInt8] = [0, 0, 0, 1] + Array("mdat".utf8)
        + [0, 0, 0, 0, 0, 0, 0, 24] + [UInt8](repeating: 7, count: 8)

    func testBoxesThatFillTheFileAreComplete() throws {
        XCTAssertTrue(try isComplete(ftyp + largeMdat))
        XCTAssertTrue(try isComplete(ftyp + [0, 0, 0, 0] + Array("mdat".utf8) + [9, 9, 9]))
    }

    func testCutOrPaddedBoxesAreIncomplete() throws {
        XCTAssertFalse(try isComplete(ftyp + largeMdat.dropLast()))
        XCTAssertFalse(try isComplete(ftyp + largeMdat + [0]))
        XCTAssertFalse(try isComplete(Array(ftyp.dropLast())))
    }
}
