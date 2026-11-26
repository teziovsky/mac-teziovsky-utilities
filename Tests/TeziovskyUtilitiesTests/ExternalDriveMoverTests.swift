import Darwin
import Foundation
@testable import TeziovskyUtilities
import XCTest

final class ExternalDriveMoverTests: XCTestCase {
    var root: URL!
    var src: URL!
    var dst: URL!
    var trash: MoverFakeTrash!
    let tagsXattr = "com.apple.metadata:_kMDItemUserTags"
    let quarantine = "0081;00000000;Safari;"
    let changedMessage = "Changed since the check. Check again (⌘R)."

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mover-\(UUID().uuidString)", isDirectory: true)
        src = root.appendingPathComponent("src", isDirectory: true)
        dst = root.appendingPathComponent("dst", isDirectory: true)
        for folder in [src!, dst!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        trash = try MoverFakeTrash(folder: root.appendingPathComponent("Trash", isDirectory: true))
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        // Clear user flags (UF_HIDDEN etc.) so the folder can always be removed.
        if let paths = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in paths {
                lchflags(root.appendingPathComponent(path).path, 0)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    func setXattr(_ name: String, _ value: String, on url: URL) {
        let bytes = Array(value.utf8)
        XCTAssertEqual(setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW), 0, "errno \(errno)")
    }

    /// Exact nanosecond birth and modification times, in one call.
    func setDates(created: Int64, modified: Int64, on url: URL) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        func spec(_ value: Int64) -> timespec {
            timespec(tv_sec: Int(value / 1_000_000_000), tv_nsec: Int(value % 1_000_000_000))
        }
        var buffer = (spec(created), spec(modified))
        let result = setattrlist(url.path, &list, &buffer, MemoryLayout<timespec>.size * 2, UInt32(FSOPT_NOFOLLOW))
        XCTAssertEqual(result, 0, "setattrlist failed: errno \(errno)")
    }

    static func nanoseconds(_ iso: String, extra: Int64 = 0) -> Int64 {
        let date = ISO8601DateFormatter().date(from: iso)!
        return Int64(date.timeIntervalSince1970) * 1_000_000_000 + extra
    }

    @discardableResult
    func makeSource(_ relativePath: String, contents: Data = Data("photo bytes".utf8),
                    hidden: Bool = false, locked: Bool = false) throws -> URL {
        let url = src.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url)
        setXattr(tagsXattr, "tag", on: url)
        setXattr("com.apple.quarantine", quarantine, on: url)
        if hidden { XCTAssertEqual(lchflags(url.path, UInt32(UF_HIDDEN)), 0) }
        setDates(created: Self.nanoseconds("2019-03-07T10:00:00Z", extra: 123_456_789),
                 modified: Self.nanoseconds("2019-03-08T11:30:00Z", extra: 987_654_321), on: url)
        // Locked last: an immutable file refuses the other writes.
        if locked {
            let flags = UInt32(UF_IMMUTABLE) | (hidden ? UInt32(UF_HIDDEN) : 0)
            XCTAssertEqual(lchflags(url.path, flags), 0)
        }
        return url
    }

    func fingerprints(_ paths: [String]) throws -> [String: FileMetadataFingerprint] {
        var result: [String: FileMetadataFingerprint] = [:]
        for path in paths {
            result[path] = try FileMetadataFingerprint.read(src.appendingPathComponent(path), includeContent: false)
        }
        return result
    }

    func unit(_ paths: [String]) -> ExternalDriveUnit {
        ExternalDriveUnit(relativePaths: paths, byteCount: 0)
    }

    func move(_ paths: [String], mover: ExternalDriveMover? = nil,
              checked: [String: FileMetadataFingerprint]? = nil,
              destinationRoot: URL? = nil,
              progress: @escaping @Sendable (Int64) -> Bool = { _ in true }) throws
        -> ExternalDriveUnitOutcome {
        let mover = mover ?? ExternalDriveMover(trash: trash.trash)
        return mover.move(unit(paths), sourceRoot: src, destinationRoot: destinationRoot ?? dst,
                          checkedFingerprints: try checked ?? fingerprints(paths), progress: progress)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Every entry (files and folders) under the destination root.
    func destinationEntries() -> [String] {
        (FileManager.default.enumerator(atPath: dst.path)?.allObjects as? [String] ?? []).sorted()
    }

    func identical(_ source: FileMetadataFingerprint, _ destination: URL) throws -> [MetadataDifference] {
        FileMetadataFingerprint.differences(
            source: source, destination: try .read(destination, includeContent: true), resolution: .microsecond)
    }

    // MARK: Tests

    func testMovesFileKeepingDatesFlagsXattrsAndTrashesOriginal() throws {
        for (name, hidden) in [("2019/visible.jpg", false), ("2019/hidden.jpg", true)] {
            let source = try makeSource(name, hidden: hidden)
            let before = try FileMetadataFingerprint.read(source, includeContent: true)
            XCTAssertEqual(before.flags & UInt32(UF_HIDDEN) != 0, hidden)

            XCTAssertEqual(try move([name]), .moved, name)

            let destination = dst.appendingPathComponent(name)
            XCTAssertEqual(try identical(before, destination), [], name)
            let after = try FileMetadataFingerprint.read(destination, includeContent: false)
            XCTAssertEqual(after.creationNanoseconds, before.creationNanoseconds, name)
            XCTAssertEqual(after.modificationNanoseconds, before.modificationNanoseconds, name)
            XCTAssertFalse(exists(source), name)
            XCTAssertTrue(trash.trashed.contains(source), name)
        }
    }

    /// exFAT's copyfile drops UF_HIDDEN; the mover must put the source's flags back.
    func testFlagsDroppedByTheCopyAreRestored() throws {
        let source = try makeSource("hidden.jpg", hidden: true)
        let before = try FileMetadataFingerprint.read(source, includeContent: true)
        let copier = MoverHookCopier { partial in XCTAssertEqual(lchflags(partial.path, 0), 0) }

        XCTAssertEqual(try move(["hidden.jpg"], mover: ExternalDriveMover(copier: copier, trash: trash.trash)), .moved)
        XCTAssertEqual(try identical(before, dst.appendingPathComponent("hidden.jpg")), [])
    }

    func testDestinationExistsIsNeverOverwritten() throws {
        try makeSource("a.jpg")
        let destination = dst.appendingPathComponent("a.jpg")
        try Data("existing".utf8).write(to: destination)

        XCTAssertEqual(try move(["a.jpg"]), .alreadyOnDestination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        XCTAssertTrue(trash.trashed.isEmpty)
        XCTAssertTrue(exists(src.appendingPathComponent("a.jpg")))
    }

    func testDanglingSymlinkAtDestinationCountsAsExisting() throws {
        try makeSource("a.jpg")
        let destination = dst.appendingPathComponent("a.jpg")
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "/nonexistent/x")

        XCTAssertEqual(try move(["a.jpg"]), .alreadyOnDestination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "/nonexistent/x")
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testDestinationCreatedAfterCheckIsNotOverwritten() throws {
        try makeSource("2019/a.jpg")
        let destination = dst.appendingPathComponent("2019/a.jpg")
        let copier = MoverHookCopier { partial in
            XCTAssertEqual(partial.lastPathComponent, ".a.jpg.partial")
            try Data("raced".utf8).write(to: destination)
        }
        let outcome = try move(["2019/a.jpg"], mover: ExternalDriveMover(copier: copier, trash: trash.trash))

        XCTAssertEqual(outcome, .alreadyOnDestination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("raced".utf8))
        XCTAssertFalse(exists(dst.appendingPathComponent("2019/.a.jpg.partial")))
        XCTAssertTrue(exists(src.appendingPathComponent("2019/a.jpg")))
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testSourceModifiedAfterCheckFailsWithoutTrashing() throws {
        let source = try makeSource("a.jpg")
        let checked = try fingerprints(["a.jpg"])
        let mtime = checked["a.jpg"]!.modificationNanoseconds
        setDates(created: checked["a.jpg"]!.creationNanoseconds, modified: mtime + 1_000_000_000, on: source)

        XCTAssertEqual(try move(["a.jpg"], checked: checked), .failed(changedMessage))
        XCTAssertEqual(destinationEntries(), [])
        XCTAssertTrue(exists(source))
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testMissingSourceOrFingerprintFailsAsChanged() throws {
        let source = try makeSource("a.jpg")
        let checked = try fingerprints(["a.jpg"])
        XCTAssertEqual(try move(["a.jpg"], checked: [:]), .failed(changedMessage))
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try move(["a.jpg"], checked: checked), .failed(changedMessage))
        XCTAssertEqual(destinationEntries(), [])
    }

    func testVerificationFailureRollsBackTheWholeUnit() throws {
        let still = "2019/IMG_0001.HEIC"
        let motion = "2019/IMG_0001.MOV"
        try makeSource(still, contents: Data("still image".utf8))
        try makeSource(motion, contents: Data("motion video".utf8))
        let log = MoverLogRecorder()
        let copier = MoverHookCopier { partial in
            guard partial.lastPathComponent == ".IMG_0001.MOV.partial" else { return }
            var data = try Data(contentsOf: partial)
            data[0] ^= 0xFF
            try data.write(to: partial)
        }
        let mover = ExternalDriveMover(copier: copier, trash: trash.trash, log: log.append)

        let outcome = try move([still, motion], mover: mover)

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasPrefix("Copied, but content differs: "), message)
        XCTAssertEqual(destinationEntries(), [], "the unit leaves no copies or folders")
        XCTAssertTrue(exists(src.appendingPathComponent(still)))
        XCTAssertTrue(exists(src.appendingPathComponent(motion)))
        XCTAssertTrue(trash.trashed.isEmpty)
        XCTAssertTrue(log.lines.contains { $0.contains(motion) && $0.contains("content") && $0.contains("→") },
                      "\(log.lines)")
    }

    func testRollbackKeepsPreExistingFolders() throws {
        try makeSource("2019/a.jpg")
        let existingFolder = dst.appendingPathComponent("2019")
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        let copier = MoverHookCopier { partial in try Data("corrupt!!!!".utf8).write(to: partial) }

        let outcome = try move(["2019/a.jpg"], mover: ExternalDriveMover(copier: copier, trash: trash.trash))

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(destinationEntries(), ["2019"])
    }

    func testCancelMidCopyLeavesNoPartialAndKeepsSource() throws {
        let contents = Data((0..<(16 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = try makeSource("2019/big.mov", contents: contents)
        let calls = MoverProgressRecorder()

        let outcome = try move(["2019/big.mov"]) { bytes in
            calls.append(bytes)
            return false
        }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(calls.values.isEmpty)
        XCTAssertEqual(destinationEntries(), [])
        XCTAssertTrue(exists(source))
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testCopyfileCopierStopsWhenAskedAndReportsProgress() throws {
        let contents = Data((0..<(16 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let source = try makeSource("big.mov", contents: contents)
        let copier = CopyfileCopier()

        var seen: [Int64] = []
        XCTAssertThrowsError(try copier.copy(from: source, to: dst.appendingPathComponent("stopped"),
                                             progress: { seen.append($0); return false })) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(seen.count, 1)

        seen = []
        let full = dst.appendingPathComponent("full")
        try copier.copy(from: source, to: full, progress: { seen.append($0); return true })
        XCTAssertEqual(seen.last, Int64(contents.count))
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(try Data(contentsOf: full), contents)

        XCTAssertThrowsError(try copier.copy(from: source, to: full, progress: { _ in true }),
                             "COPYFILE_EXCL never overwrites")
    }

    func testUnitProgressIsCumulativeAcrossMembers() throws {
        try makeSource("a.heic", contents: Data(repeating: 1, count: 3000))
        try makeSource("a.mov", contents: Data(repeating: 2, count: 5000))
        let calls = MoverProgressRecorder()

        XCTAssertEqual(try move(["a.heic", "a.mov"]) { calls.append($0); return true }, .moved)

        XCTAssertEqual(calls.values, calls.values.sorted())
        XCTAssertTrue(calls.values.contains(3000), "\(calls.values)")
        XCTAssertEqual(calls.values.last, 8000)
    }

    func testStalePartialIsReplaced() throws {
        try makeSource("2019/a.jpg", contents: Data("fresh".utf8))
        let folder = dst.appendingPathComponent("2019")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stale leftovers".utf8).write(to: folder.appendingPathComponent(".a.jpg.partial"))

        XCTAssertEqual(try move(["2019/a.jpg"]), .moved)
        XCTAssertEqual(destinationEntries(), ["2019", "2019/a.jpg"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a.jpg")), Data("fresh".utf8))
    }

    func testTrashFailureKeepsVerifiedCopy() throws {
        let source = try makeSource("a.jpg")
        let before = try FileMetadataFingerprint.read(source, includeContent: true)
        let log = MoverLogRecorder()
        let mover = ExternalDriveMover(trash: { _ in throw CocoaError(.fileWriteNoPermission) }, log: log.append)

        let outcome = try move(["a.jpg"], mover: mover)

        guard case .verifiedButNotTrashed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasPrefix("Copied and verified, but the original couldn't be moved to the Trash: "),
                      message)
        XCTAssertTrue(exists(source))
        XCTAssertEqual(try identical(before, dst.appendingPathComponent("a.jpg")), [])
        XCTAssertFalse(log.lines.isEmpty)
    }

    func testDestinationUnavailableWhenRootIsMissing() throws {
        let source = try makeSource("2019/a.jpg")
        let gone = root.appendingPathComponent("Volumes/MEDIA", isDirectory: true)

        XCTAssertEqual(try move(["2019/a.jpg"], destinationRoot: gone), .destinationUnavailable)
        XCTAssertFalse(exists(root.appendingPathComponent("Volumes")), "the drive's mount point is never created")
        XCTAssertTrue(exists(source))
    }

}

// MARK: - Test doubles

/// Moves files into a temporary folder instead of the real Trash and records what it got.
final class MoverFakeTrash: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private var urls: [URL] = []

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var trashed: [URL] { lock.withLock { urls } }

    var trash: @Sendable (URL) throws -> Void {
        { [self] url in
            // The real Trash takes a Finder-"Locked" file; a plain rename doesn't, so unlock it first.
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                lchflags(url.path, info.st_flags & ~UInt32(UF_IMMUTABLE))
            }
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(UUID().uuidString))
            lock.withLock { urls.append(url) }
        }
    }
}

/// Copies for real, then runs `afterCopy` on the partial file.
struct MoverHookCopier: ExternalDriveCopying {
    let afterCopy: @Sendable (URL) throws -> Void

    func copy(from source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try CopyfileCopier().copy(from: source, to: destination, progress: progress)
        try afterCopy(destination)
    }
}

final class MoverLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    var append: @Sendable (String) -> Void { { [self] line in lock.withLock { stored.append(line) } } }
}

final class MoverProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int64] = []
    var values: [Int64] { lock.withLock { stored } }
    func append(_ value: Int64) { lock.withLock { stored.append(value) } }
}
