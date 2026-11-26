import Darwin
import Foundation
@testable import TeziovskyUtilities
import XCTest

// Flushing the copies to the drive before any original is trashed, and pinning the drive's volume.
extension ExternalDriveMoverTests {
    func testFailingFlushNeverTrashesAndLeavesNothingOnTheDrive() throws {
        let source = try makeSource("2019/a.jpg")
        let mover = ExternalDriveMover(trash: trash.trash, flush: { _, _ in throw POSIXError(.EIO) })

        let outcome = try move(["2019/a.jpg"], mover: mover)

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasPrefix("Couldn't flush the copy to dst: "), message)
        XCTAssertTrue(trash.trashed.isEmpty)
        XCTAssertEqual(destinationEntries(), [])
        XCTAssertTrue(exists(source))
    }

    func testFlushGetsEveryFinishedCopyBeforeTheOriginalsAreTrashed() throws {
        let still = "2019/IMG_0001.HEIC"
        let motion = "2019/IMG_0001.MOV"
        try makeSource(still)
        try makeSource(motion, contents: Data("motion".utf8))
        let recorder = MoverFlushRecorder()
        let fake = trash.trash
        let mover = ExternalDriveMover(
            trash: { url in
                recorder.note("trash \(url.lastPathComponent)")
                try fake(url)
            },
            flush: { files, root in
                for file in files where !FileManager.default.fileExists(atPath: file.path) {
                    XCTFail("\(file.path) isn't at its final name when flushed")
                }
                let names = files.map(\.lastPathComponent).joined(separator: ",")
                recorder.note("flush \(names) on \(root.lastPathComponent)")
            })

        XCTAssertEqual(try move([still, motion], mover: mover), .moved)
        XCTAssertEqual(recorder.events, [
            "flush IMG_0001.HEIC,IMG_0001.MOV on dst", "trash IMG_0001.HEIC", "trash IMG_0001.MOV"
        ])
    }

    func testRealFlushSucceedsOnALocalVolume() throws {
        try makeSource("2019/a.jpg")
        XCTAssertEqual(try move(["2019/a.jpg"]), .moved)
        XCTAssertNoThrow(try ExternalDriveMoverFileSystem.flush(
            [dst.appendingPathComponent("2019/a.jpg")], destinationRoot: dst))
    }
}

final class MoverFlushRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var events: [String] { lock.withLock { stored } }
    func note(_ event: String) { lock.withLock { stored.append(event) } }
}

// MARK: - Pinned volume

extension ExternalDriveMoverTests {
    func testADifferentVolumeAtTheDrivePathIsUnavailable() throws {
        let source = try makeSource("2019/a.jpg")
        let mover = ExternalDriveMover(trash: trash.trash, deviceID: { _ in 2 })

        let outcome = mover.move(unit(["2019/a.jpg"]), sourceRoot: src, destinationRoot: dst, destinationDevice: 1,
                                 checkedFingerprints: try fingerprints(["2019/a.jpg"]), progress: { _ in true })
        XCTAssertEqual(outcome, .destinationUnavailable)
        XCTAssertEqual(mover.trashOriginalIfIdentical(unit(["2019/a.jpg"]), sourceRoot: src, destinationRoot: dst,
                                                      destinationDevice: 1),
                       .destinationUnavailable)

        XCTAssertEqual(destinationEntries(), [])
        XCTAssertTrue(exists(source))
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testTheSameVolumeMoves() throws {
        try makeSource("2019/a.jpg")
        let mover = ExternalDriveMover(trash: trash.trash)
        let device = try XCTUnwrap(mover.destinationDevice(dst))
        var info = stat()
        XCTAssertEqual(stat(dst.path, &info), 0)
        XCTAssertEqual(device, info.st_dev)

        let outcome = mover.move(unit(["2019/a.jpg"]), sourceRoot: src, destinationRoot: dst,
                                 destinationDevice: device,
                                 checkedFingerprints: try fingerprints(["2019/a.jpg"]), progress: { _ in true })
        XCTAssertEqual(outcome, .moved)
    }
}
