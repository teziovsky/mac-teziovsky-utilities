import Foundation
import XCTest
@testable import TeziovskyUtilities

/// Moves files into a folder outside the scanned one instead of the real Trash.
private final class FolderTrash: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var items: [String] = []

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var trashedNames: [String] { lock.withLock { items } }

    func trash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        lock.withLock { items.append(url.lastPathComponent) }
    }
}

private struct BrokenCopy: LocalizedError {
    var errorDescription: String? { "The copy is broken" }
}

@MainActor
final class LocalMediaReplacementRunTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var trash: FolderTrash!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMediaReplacementRunTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trash = try FolderTrash(folder: base.appendingPathComponent("trash", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    func testReplacesIncludedPairsSkipsExcludedOnesAndRescans() async throws {
        try writePair("Mia.mp4", copy: "Mia-converted.mp4")
        try writePair("Broken.mp4", copy: "Broken-converted.mp4")
        try writePair("Skip.mp4", copy: "Skip-converted.mp4")
        let service = LocalPhotosService()
        let trash = trash!
        service.makeReplacer = {
            LocalMediaReplacer(trash: { try trash.trash($0) }, verify: { pair in
                if pair.originalRelativePath == "Broken.mp4" { throw BrokenCopy() }
            })
        }
        service.scan(directory: root)
        try await waitUntilIdle(service)
        XCTAssertEqual(service.replaceablePairs.count, 3)
        XCTAssertEqual(service.scannedFileCount, 6)
        service.setExcluded(true, path: "Skip.mp4", in: .replacement)

        service.replaceOriginals()
        XCTAssertTrue(service.isReplacing)
        XCTAssertEqual(service.activityTitle, "Replacing originals")
        try await waitUntilIdle(service)

        XCTAssertEqual(trash.trashedNames, ["Mia.mp4"])
        XCTAssertTrue(exists("Mia.mp4"), "The copy takes the original's name")
        XCTAssertFalse(exists("Mia-converted.mp4"))
        XCTAssertTrue(exists("Broken.mp4") && exists("Broken-converted.mp4"), "A failed pair is untouched")
        XCTAssertTrue(exists("Skip.mp4") && exists("Skip-converted.mp4"), "An excluded pair is untouched")
        XCTAssertEqual(
            service.replaceablePairs.map(\.originalRelativePath), ["Broken.mp4", "Skip.mp4"],
            "The rescan drops the replaced pair"
        )
        XCTAssertEqual(service.scannedFileCount, 5, "Only a real rescan sees one file fewer")
        XCTAssertFalse(service.failures.contains { $0.message.contains("could not refresh") })
        XCTAssertTrue(service.isExcluded(path: "Skip.mp4", in: .replacement), "Exclusions survive the rescan")
        XCTAssertEqual(service.workflowStep, .convert)
        let summary = try XCTUnwrap(service.replacementSummary)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.cancelled, 0)
        XCTAssertEqual(summary.issues.map(\.relativePath), ["Broken.mp4"])
        XCTAssertEqual(summary.issues.first?.message, "The copy is broken")
    }

    func testCopyThatCannotTakeTheNameIsReportedWithItsKeptName() async throws {
        try writePair("Mia.mov", copy: "Mia-converted.mp4")
        try Data([9]).write(to: root.appendingPathComponent("Mia.mp4"))
        let service = LocalPhotosService()
        let trash = trash!
        service.makeReplacer = { LocalMediaReplacer(trash: { try trash.trash($0) }, verify: { _ in }) }
        service.scan(directory: root)
        try await waitUntilIdle(service)
        XCTAssertEqual(service.replaceablePairs.map(\.finalName), ["Mia.mp4"])

        service.replaceOriginals()
        try await waitUntilIdle(service)

        let summary = try XCTUnwrap(service.replacementSummary)
        XCTAssertEqual(summary.replaced, 0)
        XCTAssertEqual(summary.keptCopyName, 1)
        XCTAssertEqual(
            summary.issues.map(\.message),
            ["Original trashed; copy kept as Mia-converted.mp4 because Mia.mp4 exists"]
        )
        XCTAssertEqual(trash.trashedNames, ["Mia.mov"])
        XCTAssertTrue(exists("Mia-converted.mp4") && exists("Mia.mp4"))
        XCTAssertTrue(service.replaceablePairs.isEmpty)
    }

    func testCancelCountsUnfinishedPairsAsCancelledAndKeepsWhatWasDone() async throws {
        try writePair("A.mp4", copy: "A-converted.mp4")
        try writePair("B.mp4", copy: "B-converted.mp4")
        try writePair("C.mp4", copy: "C-converted.mp4")
        let service = LocalPhotosService()
        let trash = trash!
        service.makeReplacer = {
            LocalMediaReplacer(trash: { try trash.trash($0) }, verify: { pair in
                if pair.originalRelativePath == "B.mp4" {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
            })
        }
        service.scan(directory: root)
        try await waitUntilIdle(service)

        service.replaceOriginals()
        let deadline = Date().addingTimeInterval(10)
        while service.replacementProgress.processed < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        service.cancel()
        try await waitUntilIdle(service)

        let summary = try XCTUnwrap(service.replacementSummary)
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(summary.cancelled, 2, "B was cancelled mid-check and C was never tried")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(summary.issues.isEmpty)
        XCTAssertEqual(trash.trashedNames, ["A.mp4"])
        XCTAssertTrue(exists("B.mp4") && exists("C.mp4"))
        XCTAssertEqual(
            service.replaceablePairs.map(\.originalRelativePath), ["B.mp4", "C.mp4"],
            "The replaced pair leaves the list even without a rescan"
        )
        XCTAssertTrue(service.cancellationMessage?.contains("Replacement cancelled") == true)
    }

    // MARK: - Helpers

    private func writePair(_ original: String, copy: String) throws {
        let originalURL = root.appendingPathComponent(original)
        try Data([1, 2, 3]).write(to: originalURL)
        try Data([4, 5, 6]).write(to: root.appendingPathComponent(copy))
        let value = Array(copy.utf8)
        XCTAssertEqual(
            setxattr(originalURL.path, "com.teziovsky.utilities.converted-media", value, value.count, 0, 0), 0
        )
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func waitUntilIdle(_ service: LocalPhotosService) async throws {
        let deadline = Date().addingTimeInterval(30)
        try await Task.sleep(nanoseconds: 20_000_000)
        while service.isRunning {
            guard Date() < deadline else { return XCTFail("Service did not finish") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
