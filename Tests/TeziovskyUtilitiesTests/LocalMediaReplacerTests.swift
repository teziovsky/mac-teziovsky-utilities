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
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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

    func testVideoCopyThatDoesNotDecodeFails() async throws {
        let original = root.appendingPathComponent("Clip.mov")
        try await TestVideoFactory.makeVideo(at: original, seconds: 1)
        let copy = root.appendingPathComponent("Clip.mp4")
        try await TestVideoFactory.makeHEV1Video(at: copy, seconds: 1, fileType: .mp4)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertNotNil(error)
    }

    func testBrokenVideoCopyFails() async throws {
        let original = root.appendingPathComponent("Clip.mov")
        try await TestVideoFactory.makeVideo(at: original, seconds: 1)
        let copy = root.appendingPathComponent("Clip.mp4")
        try Data([1, 2, 3]).write(to: copy)

        let error = await verifyError(pair(original, copy, isVideo: true))
        XCTAssertEqual(error, "The converted copy isn't playable")
    }
}
