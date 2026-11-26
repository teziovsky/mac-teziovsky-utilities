import Darwin
import Foundation
@testable import TeziovskyUtilities
import XCTest

// Already-on-destination handling, rename strategies, locked files and cancellation edges.
extension ExternalDriveMoverTests {
    func testTrashOriginalIfIdenticalTrashesOnlyWhenIdentical() throws {
        // An identical copy: a move whose trash step failed leaves one behind.
        let source = try makeSource("same.jpg")
        let keepingMover = ExternalDriveMover(trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        guard case .verifiedButNotTrashed = try move(["same.jpg"], mover: keepingMover) else {
            return XCTFail("fixture")
        }
        let mover = ExternalDriveMover(trash: trash.trash)
        XCTAssertEqual(mover.trashOriginalIfIdentical(unit(["same.jpg"]), sourceRoot: src, destinationRoot: dst),
                       .trashedOriginal)
        XCTAssertEqual(trash.trashed, [source])

        let other = try makeSource("other.jpg", contents: Data("mine".utf8))
        try Data("theirs".utf8).write(to: dst.appendingPathComponent("other.jpg"))
        let outcome = mover.trashOriginalIfIdentical(unit(["other.jpg"]), sourceRoot: src, destinationRoot: dst)
        guard case .differentFileOnDestination(let summary) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(exists(other))
        XCTAssertEqual(trash.trashed, [source])
    }

    func testTrashOriginalIfIdenticalNeverTrashesTheOnlyCopy() throws {
        let source = try makeSource("a.jpg")
        let mover = ExternalDriveMover(trash: trash.trash)

        let sameRoot = mover.trashOriginalIfIdentical(unit(["a.jpg"]), sourceRoot: src, destinationRoot: src)
        guard case .failed = sameRoot else { return XCTFail("\(sameRoot)") }

        let missing = mover.trashOriginalIfIdentical(unit(["a.jpg"]), sourceRoot: src, destinationRoot: dst)
        guard case .failed = missing else { return XCTFail("\(missing)") }

        try FileManager.default.createSymbolicLink(at: dst.appendingPathComponent("a.jpg"), withDestinationURL: source)
        let link = mover.trashOriginalIfIdentical(unit(["a.jpg"]), sourceRoot: src, destinationRoot: dst)
        guard case .failed = link else { return XCTFail("\(link)") }

        XCTAssertTrue(exists(source))
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testTrashOriginalIfIdenticalSkipsAMemberAlreadyTrashed() throws {
        let still = "IMG_0002.HEIC"
        let motion = "IMG_0002.MOV"
        try makeSource(still)
        let motionSource = try makeSource(motion, contents: Data("motion".utf8))
        let keepingMover = ExternalDriveMover(trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        guard case .verifiedButNotTrashed = try move([still, motion], mover: keepingMover) else {
            return XCTFail("fixture")
        }
        // An earlier run trashed the still but not the motion file.
        try FileManager.default.removeItem(at: src.appendingPathComponent(still))

        let mover = ExternalDriveMover(trash: trash.trash)
        XCTAssertEqual(mover.trashOriginalIfIdentical(unit([still, motion]), sourceRoot: src, destinationRoot: dst),
                       .trashedOriginal)
        XCTAssertEqual(trash.trashed, [motionSource])
    }

    func testTrashOriginalIfIdenticalTriesEveryMember() throws {
        let still = "IMG_0003.HEIC"
        let motion = "IMG_0003.MOV"
        try makeSource(still)
        let motionSource = try makeSource(motion, contents: Data("motion".utf8))
        let keepingMover = ExternalDriveMover(trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        guard case .verifiedButNotTrashed = try move([still, motion], mover: keepingMover) else {
            return XCTFail("fixture")
        }
        let fake = trash.trash
        let mover = ExternalDriveMover(trash: { url in
            if url.lastPathComponent == still { throw CocoaError(.fileWriteNoPermission) }
            try fake(url)
        })

        let outcome = mover.trashOriginalIfIdentical(unit([still, motion]), sourceRoot: src, destinationRoot: dst)

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("Trash"), message)
        XCTAssertEqual(trash.trashed, [motionSource])
        XCTAssertTrue(exists(src.appendingPathComponent(still)))
    }

    func testEmptyUnitFails() {
        let mover = ExternalDriveMover(trash: trash.trash)
        XCTAssertEqual(mover.move(unit([]), sourceRoot: src, destinationRoot: dst, checkedFingerprints: [:],
                                  progress: { _ in true }), .failed("Nothing to move"))
        XCTAssertEqual(mover.trashOriginalIfIdentical(unit([]), sourceRoot: src, destinationRoot: dst),
                       .failed("Nothing to move"))
    }

    /// A Finder-"Locked" source: copyfile copies `uchg`, which would block the rename and the fix-ups.
    func testLockedSourceIsMovedAndTheCopyStaysLocked() throws {
        let source = try makeSource("locked.jpg", locked: true)
        let before = try FileMetadataFingerprint.read(source, includeContent: true)
        XCTAssertNotEqual(before.flags & UInt32(UF_IMMUTABLE), 0)

        XCTAssertEqual(try move(["locked.jpg"]), .moved)

        let destination = dst.appendingPathComponent("locked.jpg")
        XCTAssertEqual(try identical(before, destination), [])
        let flags = try FileMetadataFingerprint.read(destination, includeContent: false).flags
        XCTAssertNotEqual(flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertTrue(trash.trashed.contains(source))
    }

    /// exFAT (FSKit) has no RENAME_EXCL; the fallback must still never replace an existing file.
    func testRenameFallbackWithoutExclusiveRenameNeverReplaces() throws {
        let partial = dst.appendingPathComponent(".a.jpg.partial")
        let final = dst.appendingPathComponent("a.jpg")
        try Data("copy".utf8).write(to: partial)

        XCTAssertNil(ExternalDriveMoverFileSystem.renameReservingName(from: partial, to: final))
        XCTAssertEqual(try Data(contentsOf: final), Data("copy".utf8))
        XCTAssertFalse(exists(partial))

        try Data("second".utf8).write(to: partial)
        XCTAssertEqual(ExternalDriveMoverFileSystem.renameReservingName(from: partial, to: final)?.code, .EEXIST)
        XCTAssertEqual(try Data(contentsOf: final), Data("copy".utf8))
        XCTAssertEqual(try Data(contentsOf: partial), Data("second".utf8))

        let link = dst.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/x")
        XCTAssertEqual(ExternalDriveMoverFileSystem.renameReservingName(from: partial, to: link)?.code, .EEXIST)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "/nonexistent/x")
    }

    func testRaceOnSecondMemberRollsBackTheFirstWithEitherRenameStrategy() throws {
        for strategy in [ExternalDriveRenameStrategy.exclusiveRename, .reserveName] {
            let folder = "\(strategy)"
            let still = "\(folder)/IMG.HEIC"
            let motion = "\(folder)/IMG.MOV"
            try makeSource(still)
            try makeSource(motion, contents: Data("motion".utf8))
            let raced = dst.appendingPathComponent(motion)
            let copier = MoverHookCopier { partial in
                if partial.lastPathComponent == ".IMG.MOV.partial" { try Data("raced".utf8).write(to: raced) }
            }
            let mover = ExternalDriveMover(copier: copier, trash: trash.trash, renameStrategy: strategy)

            XCTAssertEqual(try move([still, motion], mover: mover), .alreadyOnDestination, folder)
            XCTAssertEqual(destinationEntries().filter { $0.hasPrefix(folder) }, [folder, motion], folder)
            XCTAssertEqual(try Data(contentsOf: raced), Data("raced".utf8), folder)
            XCTAssertTrue(exists(src.appendingPathComponent(still)), folder)
        }
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testMoveThroughTheReserveNameFallback() throws {
        let source = try makeSource("2019/a.jpg")
        let before = try FileMetadataFingerprint.read(source, includeContent: true)
        let mover = ExternalDriveMover(trash: trash.trash, renameStrategy: .reserveName)

        XCTAssertEqual(try move(["2019/a.jpg"], mover: mover), .moved)
        XCTAssertEqual(try identical(before, dst.appendingPathComponent("2019/a.jpg")), [])
        XCTAssertEqual(destinationEntries(), ["2019", "2019/a.jpg"])
    }

    /// The first progress call after the copy, and the one before verification, can both cancel.
    func testCancelAfterCopyBeforeVerificationRollsBack() throws {
        for stopAt in 1...2 {
            let name = "cancel\(stopAt).jpg"
            let source = try makeSource(name)
            let calls = MoverProgressRecorder()
            let mover = ExternalDriveMover(copier: MoverSilentCopier(), trash: trash.trash)

            let outcome = try move([name], mover: mover) { bytes in
                calls.append(bytes)
                return calls.values.count < stopAt
            }

            XCTAssertEqual(outcome, .cancelled, "stop at call \(stopAt)")
            XCTAssertEqual(calls.values.count, stopAt)
            XCTAssertEqual(destinationEntries(), [], "stop at call \(stopAt)")
            XCTAssertTrue(exists(source))
        }
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testRemoveFileNeverTouchesAFolder() throws {
        let folder = dst.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(lchflags(folder.path, UInt32(UF_HIDDEN)), 0)

        XCTAssertNotNil(ExternalDriveMoverFileSystem.removeFile(folder))

        var info = stat()
        XCTAssertEqual(lstat(folder.path, &info), 0)
        XCTAssertEqual(info.st_flags & UInt32(UF_HIDDEN), UInt32(UF_HIDDEN), "a folder's flags are left alone")
    }

    func testUnicodePathsRoundTrip() throws {
        let path = "Święta/Wigilia 2025/żółw.jpg"
        let source = try makeSource(path)
        let before = try FileMetadataFingerprint.read(source, includeContent: true)

        XCTAssertEqual(try move([path]), .moved)
        XCTAssertEqual(try identical(before, dst.appendingPathComponent(path)), [])
        XCTAssertTrue(trash.trashed.contains(source))
    }
}

/// Copies for real without reporting progress, so the mover's own progress calls are the only ones.
struct MoverSilentCopier: ExternalDriveCopying {
    func copy(from source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try CopyfileCopier().copy(from: source, to: destination, progress: { _ in true })
    }
}
