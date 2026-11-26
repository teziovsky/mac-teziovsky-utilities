@testable import TeziovskyUtilities
import XCTest

/// Reset-clock and filesystem-epoch timestamps must never win the "oldest valid date" vote.
final class FileDateSentinelTests: XCTestCase {
    private let now = date(2026, 1, 1, timeZone: .current)
    private let realCapture = date(2015, 6, 15, hour: 14, minute: 30, timeZone: .current)

    func testIgnoresFATEpochModificationDate() {
        assertProposes(realCapture, ignoring: date(1980, 1, 1, timeZone: .current))
    }

    func testIgnoresUnixEpochInAnyTimeZone() {
        assertProposes(realCapture, ignoring: Date(timeIntervalSince1970: 0))
        assertProposes(realCapture, ignoring: Date(timeIntervalSince1970: 3_600))
    }

    func testIgnoresQuickTimeEpoch() {
        assertProposes(realCapture, ignoring: date(1904, 1, 1, timeZone: TimeZone(identifier: "UTC")!))
    }

    func testIgnoresCameraDefaultMidnightOfYear2000() {
        assertProposes(realCapture, ignoring: date(2000, 1, 1, timeZone: .current))
    }

    func testKeepsGenuineOldScanDate() {
        let scanned = date(1965, 7, 4, hour: 12, timeZone: .current)
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/scan.jpg"),
            relativePath: "scan.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: realCapture),
                FileDateEvidence(source: .exifOriginal, date: scanned)
            ],
            now: now
        )

        XCTAssertEqual(item?.proposedDate, scanned)
    }

    func testKeepsPhotoTakenOnNewYearsDayAfterMidnight() {
        let party = date(2000, 1, 1, hour: 0, minute: 12, timeZone: .current)
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/party.jpg"),
            relativePath: "party.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: realCapture),
                FileDateEvidence(source: .exifOriginal, date: party)
            ],
            now: now
        )

        XCTAssertEqual(item?.proposedDate, party)
    }

    private func assertProposes(
        _ expected: Date,
        ignoring sentinel: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2024, 3, 1, timeZone: .current)),
                FileDateEvidence(source: .filesystemModification, date: sentinel),
                FileDateEvidence(source: .exifOriginal, date: expected)
            ],
            now: now
        )

        XCTAssertEqual(item?.proposedDate, expected, "Sentinel \(sentinel) won the vote", file: file, line: line)
        XCTAssertEqual(item?.proposedSource, .exifOriginal, file: file, line: line)
    }
}

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 0,
    minute: Int = 0,
    timeZone: TimeZone
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}
