import Darwin
import Foundation
@testable import TeziovskyUtilities
import XCTest

// The drive's volume pinned for a run, and notification permission asked when a run starts.
extension ExternalDriveTransferServiceTests {
    func testADifferentVolumeMountedMidRunStopsTheRun() async throws {
        for name in ["a", "b", "c"] { try makePhoto("2024/\(name).jpg") }
        // The run pins device 7; it reads 7 for a.jpg, then another volume (8) took the drive's place.
        let devices = TransferDeviceSequence([7, 7, 8])
        let src = src!, dst = dst!
        let service = ExternalDriveTransferService(
            mover: ExternalDriveMover(trash: trash.trash, deviceID: { _ in devices.next() }),
            preflight: { _ in .ready(freeBytes: .max) },
            folders: { role in role == .source ? .resolved(src) : .resolved(dst) },
            notify: { _, _ in },
            requestNotificationPermission: {},
            log: log.append
        )
        try await checked(service)

        service.moveReady()
        try await waitUntilIdle(service)

        let summary = try XCTUnwrap(service.summary)
        XCTAssertEqual(summary.results, [
            ExternalDriveRunResult(relativePath: "2024/a.jpg", outcome: .moved),
            ExternalDriveRunResult(relativePath: "2024/b.jpg", outcome: .destinationUnavailable)
        ])
        XCTAssertEqual(summary.notAttempted, ["2024/c.jpg"])
        XCTAssertEqual(summary.stoppedReason,
                       "MEDIA is no longer the drive this run started on. Connect it and press Check Again (⌘R).")
        XCTAssertTrue(exists(src.appendingPathComponent("2024/b.jpg")))
        XCTAssertFalse(exists(dst.appendingPathComponent("2024/b.jpg")))
    }

    func testNotificationPermissionIsAskedWhenARunStarts() async throws {
        try makePhoto("2024/a.jpg")
        let requests = TransferNotifySpy()
        let gate = TransferGate()
        let src = src!, dst = dst!
        let service = ExternalDriveTransferService(
            mover: ExternalDriveMover(copier: TransferGatedCopier(gate: gate), trash: trash.trash),
            preflight: { _ in .ready(freeBytes: .max) },
            folders: { role in role == .source ? .resolved(src) : .resolved(dst) },
            notify: { _, _ in },
            requestNotificationPermission: { requests.record("permission", "") },
            log: log.append
        )
        try await checked(service)
        XCTAssertTrue(requests.calls.isEmpty, "a check alone doesn't ask")

        service.moveReady()
        XCTAssertEqual(requests.calls.count, 1, "asked as the run starts, before it finishes")
        gate.open()
        try await waitUntilIdle(service)
        XCTAssertEqual(requests.calls.count, 1)
    }
}

final class TransferDeviceSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [dev_t]

    init(_ values: [dev_t]) { self.values = values }

    /// The next value; the last one repeats.
    func next() -> dev_t? {
        lock.withLock { values.count > 1 ? values.removeFirst() : values.first }
    }
}

/// Waits at the gate, then copies for real.
struct TransferGatedCopier: ExternalDriveCopying {
    let gate: TransferGate

    func copy(from source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        gate.arriveAndWait()
        try CopyfileCopier().copy(from: source, to: destination, progress: progress)
    }
}
