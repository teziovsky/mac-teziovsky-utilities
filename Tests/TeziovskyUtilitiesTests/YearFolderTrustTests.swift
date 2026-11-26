import CoreGraphics
import Foundation
import ImageIO
@testable import TeziovskyUtilities
import XCTest

/// A year folder outranks file-system dates; New Year's Eve shoots stay together; the GPS
/// epoch is a placeholder date.
final class YearFolderTrustTests: XCTestCase {
    private let warsaw = TimeZone(identifier: "Europe/Warsaw")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YearFolderTrust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testFileSystemDateNeverMovesFileOutOfYearFolder() {
        let outcome = plan("_kuba/2014/a.jpeg", [
            FileDateEvidence(source: .filesystemCreation, date: local(2025, 7, 3, 10))
        ])

        guard case .kept(let item) = outcome else {
            return XCTFail("Expected .kept, got \(outcome)")
        }
        XCTAssertEqual(item.yearFolder, "2014")
        XCTAssertEqual(item.relativePath, "_kuba/2014/a.jpeg")
        XCTAssertEqual(item.disagreeingSource, .filesystemCreation)
        XCTAssertEqual(item.disagreeingDate, local(2025, 7, 3, 10))
    }

    func testEmbeddedDateInAnotherYearMovesFile() {
        let outcome = plan("X/2019/a.jpeg", [
            FileDateEvidence(source: .exifOriginal, date: local(2023, 2, 9, 12))
        ])

        XCTAssertEqual(moveDestination(outcome), "X/2023/a.jpeg")
    }

    func testEmbeddedDateMatchingFolderStaysDespiteOlderFileSystemDate() {
        let outcome = plan("X/2014/a.jpg", [
            FileDateEvidence(source: .exifOriginal, date: local(2014, 5, 1, 12)),
            FileDateEvidence(source: .filesystemCreation, date: local(2013, 1, 1, 0))
        ])

        XCTAssertEqual(outcome, .unchanged)
    }

    func testNewYearEveShootStaysInEitherYearFolder() {
        XCTAssertEqual(
            plan("DUEL/2022/a.jpeg", [FileDateEvidence(source: .exifOriginal, date: local(2023, 1, 1, 0, 40))]),
            .unchanged
        )
        XCTAssertEqual(
            plan("DUEL/2023/a.jpeg", [FileDateEvidence(source: .exifOriginal, date: local(2022, 12, 31, 23, 10))]),
            .unchanged
        )
        let afternoon = plan("DUEL/2022/a.jpeg", [
            FileDateEvidence(source: .exifOriginal, date: local(2023, 1, 1, 13))
        ])
        XCTAssertEqual(moveDestination(afternoon), "DUEL/2023/a.jpeg")
    }

    func testNightRuleForUnsortedFiles() {
        let night = plan("Inbox/a.jpg", [FileDateEvidence(source: .exifOriginal, date: local(2023, 1, 1, 3))])
        let morning = plan("Inbox/a.jpg", [FileDateEvidence(source: .exifOriginal, date: local(2023, 1, 1, 7))])

        XCTAssertEqual(moveDestination(night), "Inbox/2022/a.jpg")
        XCTAssertEqual(moveDestination(morning), "Inbox/2023/a.jpg")
    }

    func testExactMidnightOnFirstJanuaryIsAYearOnlyPlaceholder() {
        let midnight = local(2023, 1, 1, 0)
        let placementYear = { LocalMediaOrganizationPlanner.placementYear(for: $0, timeZone: self.warsaw) }

        XCTAssertEqual(placementYear(midnight), 2023, "1 Jan 00:00:00 stays in its own year")
        XCTAssertEqual(placementYear(midnight.addingTimeInterval(1)), 2022, "1 Jan 00:00:01 is the night before")
        XCTAssertEqual(placementYear(midnight.addingTimeInterval(0.5)), 2022, "a fraction past midnight is not exact")

        let unsorted = plan("Inbox/a.jpg", [FileDateEvidence(source: .exifOriginal, date: midnight)])
        XCTAssertEqual(moveDestination(unsorted), "Inbox/2023/a.jpg")
        let inOtherYearFolder = plan("X/2019/a.jpg", [FileDateEvidence(source: .exifOriginal, date: midnight)])
        XCTAssertEqual(moveDestination(inOtherYearFolder), "X/2023/a.jpg")
        let justAfter = plan("X/2019/a.jpg", [
            FileDateEvidence(source: .exifOriginal, date: midnight.addingTimeInterval(1))
        ])
        XCTAssertEqual(moveDestination(justAfter), "X/2022/a.jpg")
    }

    func testTIFFDateTimeAloneCannotMoveFileOutOfYearFolder() {
        let agreeingFileSystem = plan("2019/a.jpg", [
            FileDateEvidence(source: .tiffDateTime, date: local(2021, 4, 2, 12)),
            FileDateEvidence(source: .filesystemCreation, date: local(2019, 6, 1, 12))
        ])
        XCTAssertEqual(agreeingFileSystem, .unchanged)

        let disagreeing = plan("2019/a.jpg", [
            FileDateEvidence(source: .tiffDateTime, date: local(2021, 4, 2, 12)),
            FileDateEvidence(source: .filesystemCreation, date: local(2021, 6, 1, 12))
        ])
        guard case .kept(let item) = disagreeing else {
            return XCTFail("Expected .kept, got \(disagreeing)")
        }
        XCTAssertEqual(item.yearFolder, "2019")
        XCTAssertEqual(item.disagreeingDate, local(2021, 4, 2, 12))
    }

    func testTIFFDateTimeStillDecidesOutsideYearFolders() {
        let outcome = plan("Inbox/a.jpg", [
            FileDateEvidence(source: .tiffDateTime, date: local(2021, 4, 2, 12)),
            FileDateEvidence(source: .filesystemCreation, date: local(2024, 6, 1, 12))
        ])
        XCTAssertEqual(moveDestination(outcome), "Inbox/2021/a.jpg")
    }

    func testNewYearWindowUsesLocalTimeZone() {
        let lateEveningInWarsaw = utc(2022, 12, 31, 22, 30)
        let middayInWarsaw = utc(2023, 1, 1, 11, 30)

        XCTAssertTrue(LocalMediaOrganizationPlanner.isInNewYearWindow(
            lateEveningInWarsaw, nextToYearFolder: 2022, timeZone: warsaw
        ))
        XCTAssertFalse(LocalMediaOrganizationPlanner.isInNewYearWindow(
            middayInWarsaw, nextToYearFolder: 2022, timeZone: warsaw
        ))
        let placementYear = { LocalMediaOrganizationPlanner.placementYear(for: $0, timeZone: self.warsaw) }
        XCTAssertEqual(placementYear(utc(2022, 12, 31, 23, 30)), 2022)
        XCTAssertEqual(placementYear(utc(2023, 1, 1, 4, 59)), 2022, "05:59 in Warsaw is still the night before")
        XCTAssertEqual(placementYear(utc(2023, 1, 1, 5, 0)), 2023, "06:00 in Warsaw starts the new year")
    }

    func testNewYearWindowAndNightRuleBoundaries() {
        let inWindow = {
            LocalMediaOrganizationPlanner.isInNewYearWindow($0, nextToYearFolder: 2022, timeZone: self.warsaw)
        }
        let placementYear = { LocalMediaOrganizationPlanner.placementYear(for: $0, timeZone: self.warsaw) }
        let opens = local(2022, 12, 31, 12)
        let closes = local(2023, 1, 1, 12)
        let morning = local(2023, 1, 1, 6)

        XCTAssertFalse(inWindow(opens.addingTimeInterval(-1)), "31 Dec 11:59:59 is before the window")
        XCTAssertTrue(inWindow(opens), "31 Dec 12:00:00 opens the window")
        XCTAssertTrue(inWindow(closes.addingTimeInterval(-1)), "1 Jan 11:59:59 is still inside")
        XCTAssertFalse(inWindow(closes), "1 Jan 12:00:00 closes the window")
        XCTAssertEqual(placementYear(morning.addingTimeInterval(-1)), 2022, "1 Jan 05:59:59 is the night before")
        XCTAssertEqual(placementYear(morning), 2023, "1 Jan 06:00:00 is the new year")
    }

    func testGPSEpochIsIgnored() {
        let gpsEpoch = utc(1980, 1, 6, 10)
        XCTAssertTrue(FileDateRepairPlanner.isSentinel(gpsEpoch))

        let outcome = plan(
            "_rodzinka/2008/_Filmy/Video_0001.3gp",
            [FileDateEvidence(source: .filesystemCreation, date: gpsEpoch)],
            isVideo: true
        )
        XCTAssertEqual(outcome, .unchanged)
    }

    func testVideoInFilmyMovesOnEmbeddedDate() {
        let outcome = plan(
            "_rodzinka/2008/_Filmy/Video_0002.mp4",
            [
                FileDateEvidence(source: .containerCreation, date: local(2010, 8, 15, 18)),
                FileDateEvidence(source: .filesystemCreation, date: local(2024, 3, 1, 9))
            ],
            isVideo: true
        )

        XCTAssertEqual(moveDestination(outcome), "_rodzinka/2010/_Filmy/Video_0002.mp4")
        if case .move(let item) = outcome {
            XCTAssertEqual(item.proposedSource, .containerCreation)
            XCTAssertEqual(item.proposedDate, local(2010, 8, 15, 18))
        }
    }

    func testLivePhotoPairOnNewYearNightStaysTogether() {
        let shot = local(2023, 1, 1, 0, 30)
        let still = plan("2022/IMG_0001.HEIC", [FileDateEvidence(source: .exifOriginal, date: shot)])
        let motion = plan(
            "2022/IMG_0001.MOV",
            [FileDateEvidence(source: .containerCreation, date: shot)],
            isVideo: true,
            groupsWithPhotos: true
        )

        XCTAssertEqual(still, .unchanged)
        XCTAssertEqual(motion, .unchanged)
    }

    // MARK: - Helpers

    // MARK: Kept files through the scanner

    func testKeptFileCountsAsAlreadyOrganized() async throws {
        try makeUndatedJPEG("2014/a.jpg", finderDate: Date(timeIntervalSince1970: 1_751_540_400))

        let result = try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )

        XCTAssertTrue(result.organizationItems.isEmpty)
        XCTAssertEqual(result.keptItems.map(\.relativePath), ["2014/a.jpg"])
        XCTAssertEqual(result.keptItems.first?.yearFolder, "2014")
        XCTAssertEqual(result.organizationSkippedCount, 1)
    }

    func testKeptFileIsReadyForExternalDriveTransfer() async throws {
        try makeUndatedJPEG("2014/a.jpg", finderDate: Date(timeIntervalSince1970: 1_751_540_400))

        let scanned = try await FileDateRepairScanner.scanOutputs(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )
        let output = try XCTUnwrap(scanned.outputs.first)
        XCTAssertNotNil(output.keptItem)
        XCTAssertTrue(output.isAlreadyOrganized)

        let review = ExternalDriveClassifier.classify(
            scanned,
            otherFiles: [],
            byteCount: { _ in 10 },
            existsOnDestination: { _ in false }
        )
        XCTAssertEqual(review.entries.map(\.bucket), [.ready])
    }

    private func makeUndatedJPEG(_ relativePath: String, finderDate: Date) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileDatePreservation.applyFileDates(to: url, created: finderDate, modified: finderDate)
    }

    private func plan(
        _ relativePath: String,
        _ evidence: [FileDateEvidence],
        isVideo: Bool = false,
        groupsWithPhotos: Bool = false
    ) -> LocalMediaOrganizationPlan {
        LocalMediaOrganizationPlanner.plan(
            fileURL: root.appendingPathComponent(relativePath),
            relativePath: relativePath,
            rootDirectory: root,
            evidence: evidence,
            isVideo: isVideo,
            groupsWithPhotos: groupsWithPhotos,
            now: local(2026, 11, 26, 12),
            timeZone: warsaw
        )
    }

    private func moveDestination(_ outcome: LocalMediaOrganizationPlan) -> String? {
        guard case .move(let item) = outcome else {
            XCTFail("Expected .move, got \(outcome)")
            return nil
        }
        return item.destinationRelativePath
    }

    private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        date(DateComponents(year: year, month: month, day: day, hour: hour, minute: minute), in: warsaw)
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        date(
            DateComponents(year: year, month: month, day: day, hour: hour, minute: minute),
            in: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func date(_ components: DateComponents, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components)!
    }
}
