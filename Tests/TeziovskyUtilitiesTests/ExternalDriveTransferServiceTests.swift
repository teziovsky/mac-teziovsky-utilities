import Darwin
import Foundation
import ImageIO
@testable import TeziovskyUtilities
import XCTest

@MainActor
final class ExternalDriveTransferServiceTests: XCTestCase {
    var root: URL!
    var src: URL!
    var dst: URL!
    var trash: MoverFakeTrash!
    var notifications: TransferNotifySpy!
    var connection: TransferConnection!
    var log: MoverLogRecorder!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transfer-\(UUID().uuidString)", isDirectory: true)
        src = root.appendingPathComponent("src", isDirectory: true)
        dst = root.appendingPathComponent("MEDIA", isDirectory: true)
        for folder in [src!, dst!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        trash = try MoverFakeTrash(folder: root.appendingPathComponent("Trash", isDirectory: true))
        notifications = TransferNotifySpy()
        connection = TransferConnection()
        log = MoverLogRecorder()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Tests

    func testCheckBucketsAndMoveMovesOnlyReadyFiles() async throws {
        try makePhoto("2024/a.jpg")
        try makePhoto("Psy/b.jpg")
        let service = makeService()
        try await checked(service)

        let review = try XCTUnwrap(service.review)
        XCTAssertEqual(review.entries(in: .ready).map(\.relativePath), ["2024/a.jpg"])
        XCTAssertEqual(review.entries(in: .needsOrganizing).map(\.relativePath), ["Psy/b.jpg"])
        XCTAssertEqual(service.step, .review)
        XCTAssertEqual(service.destinationName, "MEDIA")

        let reachedSummary = expectation(description: "summary")
        let subscription = service.$step.sink { if $0 == .summary { reachedSummary.fulfill() } }
        service.moveReady()
        XCTAssertTrue(service.isTransferring)
        XCTAssertEqual(service.step, .moving)
        XCTAssertEqual(service.activityTitle, "Moving files to MEDIA")
        await fulfillment(of: [reachedSummary], timeout: 30)
        subscription.cancel()

        XCTAssertTrue(exists(dst.appendingPathComponent("2024/a.jpg")))
        XCTAssertFalse(exists(dst.appendingPathComponent("Psy/b.jpg")))
        XCTAssertTrue(exists(src.appendingPathComponent("Psy/b.jpg")))
        XCTAssertEqual(trash.trashed.map(\.lastPathComponent), ["a.jpg"])
        let summary = try XCTUnwrap(service.summary)
        XCTAssertEqual(summary.kind, .move)
        XCTAssertEqual(summary.succeededUnits, 1)
        XCTAssertEqual(summary.attemptedUnits, 1)
        XCTAssertEqual(summary.results, [ExternalDriveRunResult(relativePath: "2024/a.jpg", outcome: .moved)])
        XCTAssertFalse(summary.wasCancelled)
        XCTAssertNil(summary.stoppedReason)
        XCTAssertEqual(service.review, review, "the review stays for the summary's held-back lists")
        XCTAssertFalse(service.isTransferring)
        XCTAssertEqual(service.progress.bytesDone, service.progress.bytesTotal)
        XCTAssertEqual(notifications.calls.count, 1)
        XCTAssertEqual(notifications.calls.first?.title, "Move to External Drive")
        XCTAssertEqual(notifications.calls.first?.body, "Moved 1 of 1 to MEDIA")
        XCTAssertEqual(summary.totalUnits, 1)
        XCTAssertEqual(summary.notAttempted, [])
        XCTAssertEqual(log.lines, [
            "Move 1 files to MEDIA started",
            "2024/a.jpg: moved",
            "Move to MEDIA finished: 1 of 1 succeeded"
        ])
    }

    func testNotConnectedBlocksCheck() async throws {
        try makePhoto("2024/a.jpg")
        connection.isConnected = false
        let service = makeService()
        service.check()
        try await waitUntilIdle(service)

        XCTAssertNil(service.review)
        XCTAssertEqual(service.preflightState, .notConnected("gone"))
        XCTAssertEqual(service.sourceURL, src)
    }

    func testMoveWithNothingReadyDoesNotStartARun() async throws {
        try makePhoto("Psy/b.jpg")
        let service = makeService()
        try await checked(service)
        XCTAssertEqual(service.review?.readyUnits, [])

        service.moveReady()

        XCTAssertFalse(service.isTransferring)
        XCTAssertEqual(service.step, .review)
        XCTAssertNil(service.summary)
        XCTAssertTrue(notifications.calls.isEmpty)
    }

    func testNotEnoughSpaceDoesNotStart() async throws {
        try makePhoto("2024/a.jpg")
        let service = makeService(freeBytes: 1)
        try await checked(service)
        XCTAssertEqual(service.review?.readyUnits.count, 1)

        service.moveReady()

        XCTAssertFalse(service.isTransferring)
        XCTAssertEqual(service.step, .review)
        XCTAssertTrue(exists(src.appendingPathComponent("2024/a.jpg")))
        XCTAssertFalse(exists(dst.appendingPathComponent("2024")))
    }

    func testRunStopsWhenDestinationDisappears() async throws {
        try makePhoto("2024/a.jpg")
        try makePhoto("2024/b.jpg")
        let dst = dst!, connection = connection!
        let copier = MoverHookCopier { _ in
            try FileManager.default.removeItem(at: dst)
            connection.isConnected = false
        }
        let service = makeService(copier: copier)
        try await checked(service)
        XCTAssertEqual(service.review?.readyUnits.count, 2)

        service.moveReady()
        try await waitUntilIdle(service)

        let summary = try XCTUnwrap(service.summary)
        XCTAssertEqual(service.step, .summary)
        XCTAssertTrue(summary.stoppedReason?.contains("was disconnected") == true, "\(String(describing: summary))")
        XCTAssertEqual(summary.stoppedReason, "MEDIA was disconnected. Connect it and press Check Again (⌘R).")
        XCTAssertEqual(summary.attemptedUnits, 1)
        XCTAssertEqual(summary.results.map(\.relativePath), ["2024/a.jpg"])
        XCTAssertEqual(summary.succeededUnits, 0)
        XCTAssertTrue(exists(src.appendingPathComponent("2024/a.jpg")))
        XCTAssertTrue(exists(src.appendingPathComponent("2024/b.jpg")))
        XCTAssertTrue(trash.trashed.isEmpty)
        XCTAssertEqual(summary.totalUnits, 2)
        XCTAssertEqual(summary.notAttempted, ["2024/b.jpg"])
        XCTAssertFalse(summary.wasCancelled)
        XCTAssertEqual(notifications.calls.map(\.body), ["Moved 0 of 2 to MEDIA — 2 need attention (stopped)"])
        XCTAssertEqual(log.lines.first, "Move 2 files to MEDIA started")
        XCTAssertTrue(log.lines.contains { $0.hasPrefix("2024/a.jpg: failed: ") }, "\(log.lines)")
        XCTAssertEqual(log.lines.suffix(2), [
            "2024/b.jpg: not attempted",
            "Move to MEDIA stopped: MEDIA was disconnected. Connect it and press Check Again (⌘R)."
        ])
    }

    func testCancelStopsAfterCurrentUnit() async throws {
        try makePhoto("2024/a.jpg")
        try makePhoto("2024/b.jpg")
        let gate = TransferGate()
        let copier = MoverHookCopier { _ in gate.arriveAndWait() }
        let service = makeService(copier: copier)
        try await checked(service)

        service.moveReady()
        while !gate.hasArrived { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(service.progress.unitIndex, 0)
        XCTAssertEqual(service.progress.unitCount, 2)
        service.cancel()
        XCTAssertTrue(service.isTransferring, "the current unit finishes before the run stops")
        gate.open()
        try await waitUntilIdle(service)

        let summary = try XCTUnwrap(service.summary)
        XCTAssertTrue(summary.wasCancelled)
        XCTAssertEqual(summary.attemptedUnits, 1)
        XCTAssertEqual(summary.results, [ExternalDriveRunResult(relativePath: "2024/a.jpg", outcome: .cancelled)])
        XCTAssertEqual(gate.arrivals, 1, "unit 2 is never started")
        XCTAssertTrue(exists(src.appendingPathComponent("2024/a.jpg")))
        XCTAssertTrue(exists(src.appendingPathComponent("2024/b.jpg")))
        XCTAssertFalse(exists(dst.appendingPathComponent("2024/a.jpg")))
        XCTAssertFalse(exists(dst.appendingPathComponent("2024/.a.jpg.partial")))
        XCTAssertEqual(summary.notAttempted, ["2024/b.jpg"])
        XCTAssertEqual(notifications.calls.map(\.body), ["Moved 0 of 2 to MEDIA — 2 need attention (cancelled)"])
        XCTAssertEqual(log.lines, [
            "Move 2 files to MEDIA started",
            "2024/a.jpg: cancelled",
            "2024/b.jpg: not attempted",
            "Move to MEDIA cancelled: 0 of 2 succeeded"
        ])
    }

    func testTrashExistingOriginalsTrashesIdenticalOnly() async throws {
        try makePhoto("2024/a.jpg")
        try makePhoto("2024/c.jpg")
        // An exact copy of a.jpg (made by the mover, keeping the original), and a different c.jpg.
        let keeper = ExternalDriveMover(trash: { _ in })
        let fingerprint = try FileMetadataFingerprint.read(src.appendingPathComponent("2024/a.jpg"),
                                                           includeContent: false)
        XCTAssertEqual(keeper.move(ExternalDriveUnit(relativePaths: ["2024/a.jpg"], byteCount: 0),
                                   sourceRoot: src, destinationRoot: dst,
                                   checkedFingerprints: ["2024/a.jpg": fingerprint], progress: { _ in true }),
                       .moved)
        try Data("not the same photo".utf8).write(to: dst.appendingPathComponent("2024/c.jpg"))

        let service = makeService()
        try await checked(service)
        let review = try XCTUnwrap(service.review)
        XCTAssertEqual(review.existingUnits.map(\.id), ["2024/a.jpg", "2024/c.jpg"])
        XCTAssertEqual(review.readyUnits, [])

        service.trashExistingOriginals()
        XCTAssertEqual(service.activityTitle, "Moving originals already on MEDIA to the Trash")
        try await waitUntilIdle(service)

        let summary = try XCTUnwrap(service.summary)
        XCTAssertEqual(summary.kind, .trashExisting)
        XCTAssertEqual(summary.succeededUnits, 1)
        XCTAssertEqual(summary.results.first, ExternalDriveRunResult(relativePath: "2024/a.jpg",
                                                                     outcome: .trashedOriginal))
        guard case .differentFileOnDestination = summary.results.last?.outcome else {
            return XCTFail("c.jpg should differ: \(summary.results)")
        }
        XCTAssertEqual(trash.trashed.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertTrue(exists(src.appendingPathComponent("2024/c.jpg")))
        XCTAssertEqual(notifications.calls.map(\.body),
                       ["Moved 1 of 2 originals already on MEDIA to the Trash — 1 need attention"])
        XCTAssertEqual(log.lines.first, "Trash 2 originals already on MEDIA started")
        XCTAssertEqual(log.lines[1], "2024/a.jpg: original moved to the Trash")
        XCTAssertTrue(log.lines.contains { $0.hasPrefix("2024/c.jpg: different file on MEDIA: ") }, "\(log.lines)")
        XCTAssertEqual(log.lines.last, "Trash originals already on MEDIA finished: 1 of 2 succeeded")
    }

    func testResetDuringARunWaitsForTheCurrentUnit() async throws {
        try makePhoto("2024/a.jpg")
        try makePhoto("2024/b.jpg")
        let gate = TransferGate()
        let copier = MoverHookCopier { _ in gate.arriveAndWait() }
        let service = makeService(copier: copier)
        try await checked(service)
        let review = service.review

        service.moveReady()
        while !gate.hasArrived { try await Task.sleep(nanoseconds: 5_000_000) }
        service.reset()
        XCTAssertTrue(service.isTransferring, "reset only cancels while a unit is in flight")
        XCTAssertEqual(service.step, .moving)
        service.check()
        XCTAssertFalse(service.isChecking, "a check is refused while moving")
        XCTAssertEqual(service.review, review)
        service.moveReady()
        service.trashExistingOriginals()
        XCTAssertEqual(service.progress.unitIndex, 0)

        gate.open()
        try await waitUntilIdle(service)

        XCTAssertEqual(gate.arrivals, 1)
        XCTAssertEqual(service.step, .review)
        XCTAssertNil(service.summary)
        XCTAssertNil(service.review)
        XCTAssertTrue(exists(src.appendingPathComponent("2024/a.jpg")))
        XCTAssertFalse(exists(dst.appendingPathComponent("2024/a.jpg")))
        XCTAssertEqual(notifications.calls.map(\.body), ["Moved 0 of 2 to MEDIA — 2 need attention (cancelled)"])
    }

    func testGoBackFromSummaryRechecks() async throws {
        try makePhoto("2024/a.jpg")
        let service = makeService()
        try await checked(service)
        XCTAssertFalse(service.goBack(), "Back from the review leaves the workflow")

        service.moveReady()
        XCTAssertFalse(service.goBack(), "Back is blocked while moving")
        XCTAssertEqual(service.step, .moving)
        try await waitUntilIdle(service)
        XCTAssertEqual(service.step, .summary)

        XCTAssertTrue(service.goBack())
        XCTAssertEqual(service.step, .review)
        XCTAssertNil(service.summary)
        try await waitUntilIdle(service)
        XCTAssertEqual(service.review?.readyUnits, [], "the recheck sees the moved file gone")
        XCTAssertEqual(service.review?.entries, [])
    }

    func testUseSourceOverridesTheStoredFolder() async throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try makePhoto("2024/z.jpg", in: other)
        let service = makeService()

        service.useSource(other)
        try await waitUntilIdle(service)

        XCTAssertEqual(service.sourceURL, other)
        XCTAssertEqual(service.review?.readyUnits.map(\.id), ["2024/z.jpg"])
    }

    /// Choosing the source in Settings (or the review's chooser) replaces this session's ⌘O folder.
    func testForgettingTheSessionSourceChecksTheSavedFolder() async throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let service = makeService()
        service.useSource(other)
        try await waitUntilIdle(service)

        service.forgetSessionSource()
        service.check()
        try await waitUntilIdle(service)

        XCTAssertEqual(service.sourceURL, src)
    }

    /// xctest has a bundle identifier ("com.apple.dt.xctest.tool") but no app bundle; posting must not crash.
    func testNotifierIsANoOpOutsideAnAppBundle() {
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app")
        ExternalDriveNotifier.post(title: "Move to External Drive", body: "test")
    }
}

@MainActor
extension ExternalDriveTransferServiceTests {
    // MARK: Fixtures

    func makeService(copier: ExternalDriveCopying = CopyfileCopier(), freeBytes: Int64 = .max)
        -> ExternalDriveTransferService {
        let src = src!, dst = dst!, connection = connection!, notifications = notifications!
        return ExternalDriveTransferService(
            mover: ExternalDriveMover(copier: copier, trash: trash.trash),
            preflight: { _ in connection.isConnected ? .ready(freeBytes: freeBytes) : .notConnected("gone") },
            folders: { role in role == .source ? .resolved(src) : .resolved(dst) },
            notify: { title, body in notifications.record(title, body) },
            log: log.append
        )
    }

    /// A JPEG whose EXIF date and Finder Created/Modified agree (local time), so it needs no repair.
    func makePhoto(_ relativePath: String, in folder: URL? = nil, year: Int = 2024) throws {
        let url = (folder ?? src).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "\(year):06:01 12:00:00"]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var components = DateComponents(year: year, month: 6, day: 1, hour: 12)
        components.timeZone = .current
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        let nanoseconds = Int64(date.timeIntervalSince1970) * 1_000_000_000
        XCTAssertNil(ExternalDriveMoverFileSystem.setDates(created: nanoseconds, modified: nanoseconds, on: url))
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func waitUntilIdle(_ service: ExternalDriveTransferService) async throws {
        let deadline = Date().addingTimeInterval(30)
        while service.isRunning {
            guard Date() < deadline else { return XCTFail("Service did not finish") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func checked(_ service: ExternalDriveTransferService) async throws {
        service.check()
        try await waitUntilIdle(service)
        XCTAssertNotNil(service.review, "check didn't produce a review")
    }
}

// MARK: - Test doubles

final class TransferNotifySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(title: String, body: String)] = []
    var calls: [(title: String, body: String)] { lock.withLock { stored } }
    func record(_ title: String, _ body: String) { lock.withLock { stored.append((title, body)) } }
}

final class TransferConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = true
    var isConnected: Bool {
        get { lock.withLock { connected } }
        set { lock.withLock { connected = newValue } }
    }
}

/// Holds the copier (off the main thread) until the test opens it.
final class TransferGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0

    var hasArrived: Bool { lock.withLock { count > 0 } }
    var arrivals: Int { lock.withLock { count } }

    func arriveAndWait() {
        lock.withLock { count += 1 }
        semaphore.wait()
    }

    func open() { semaphore.signal() }
}
