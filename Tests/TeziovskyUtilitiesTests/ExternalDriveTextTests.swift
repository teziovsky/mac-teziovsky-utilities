import Foundation
@testable import TeziovskyUtilities
import XCTest

/// The words the Move to External Drive screens show. Sizes and durations are passed in already
/// formatted, so these tests don't depend on the Mac's locale.
final class ExternalDriveTextTests: XCTestCase {
    func testOutcomeTextForEveryNonSuccess() {
        let name = "MEDIA"
        XCTAssertNil(ExternalDriveText.outcome(.moved, destinationName: name))
        XCTAssertNil(ExternalDriveText.outcome(.trashedOriginal, destinationName: name))
        XCTAssertEqual(ExternalDriveText.outcome(.alreadyOnDestination, destinationName: name),
                       "Already on MEDIA — left in place")
        XCTAssertEqual(ExternalDriveText.outcome(.cancelled, destinationName: name), "Cancelled — nothing changed")
        XCTAssertEqual(ExternalDriveText.outcome(.failed("Copied, but size differs"), destinationName: name),
                       "Copied, but size differs")
        XCTAssertEqual(
            ExternalDriveText.outcome(.verifiedButNotTrashed("Couldn't move the original to the Trash"),
                                      destinationName: name),
            "Couldn't move the original to the Trash"
        )
        XCTAssertEqual(
            ExternalDriveText.outcome(.differentFileOnDestination("content differs"), destinationName: name),
            "A different file with this name is on MEDIA: content differs"
        )
        XCTAssertEqual(ExternalDriveText.outcome(.destinationUnavailable, destinationName: name),
                       "MEDIA wasn't reachable")
    }

    func testMoveConfirmationShowsWhereTheFirstReadyFileGoes() {
        let review = ExternalDriveReview(entries: [], readyUnits: [
            ExternalDriveUnit(relativePaths: ["2024/IMG_0001.jpg", "2024/IMG_0001.MOV"], byteCount: 1),
            ExternalDriveUnit(relativePaths: ["2024/IMG_0002.jpg"], byteCount: 1)
        ], existingUnits: [])
        XCTAssertEqual(
            ExternalDriveText.moveConfirmationMessage(review, destinationName: "MEDIA"),
            "Originals go to the Trash after each file is verified.\n2024/IMG_0001.jpg → MEDIA/2024/IMG_0001.jpg"
        )
        XCTAssertEqual(ExternalDriveText.moveConfirmationMessage(nil, destinationName: "MEDIA"),
                       "Originals go to the Trash after each file is verified.")
    }

    func testAttentionItemsListFailuresThenNotAttempted() {
        let summary = ExternalDriveRunSummary(
            kind: .move, totalUnits: 4, attemptedUnits: 2, succeededUnits: 1,
            results: [
                ExternalDriveRunResult(relativePath: "2024/a.jpg", outcome: .moved),
                ExternalDriveRunResult(relativePath: "2024/b.jpg", outcome: .failed("Copied, but size differs"))
            ],
            notAttempted: ["2024/c.jpg", "2024/d.jpg"], wasCancelled: true, stoppedReason: nil
        )
        XCTAssertEqual(ExternalDriveText.attentionItems(summary, destinationName: "MEDIA"), [
            ExternalDriveAttentionItem(relativePath: "2024/b.jpg", message: "Copied, but size differs"),
            ExternalDriveAttentionItem(relativePath: "2024/c.jpg", message: "Not attempted"),
            ExternalDriveAttentionItem(relativePath: "2024/d.jpg", message: "Not attempted")
        ])
    }

    func testReviewSummaryOmitsZeroParts() {
        let review = makeReview([.ready, .ready, .needsOrganizing, .notMedia])
        XCTAssertEqual(ExternalDriveText.reviewSummary(review, destinationName: "MEDIA"),
                       "2 ready · 1 need organizing · 1 not media")
        let full = makeReview([.ready, .needsOrganizing, .alreadyOnDestination, .notMedia])
        XCTAssertEqual(ExternalDriveText.reviewSummary(full, destinationName: "MEDIA"),
                       "1 ready · 1 need organizing · 1 already on MEDIA · 1 not media")
        XCTAssertEqual(ExternalDriveText.reviewSummary(makeReview([]), destinationName: "MEDIA"),
                       "No files in the source folder")
    }

    func testSizeLine() {
        XCTAssertEqual(ExternalDriveText.sizeLine(toMove: "12 MB", free: "1 TB", destinationName: "MEDIA"),
                       "12 MB to move · 1 TB free on MEDIA")
    }

    func testHeadlineForBothRunKinds() {
        let move = makeSummary(kind: .move, total: 240, succeeded: 238)
        XCTAssertEqual(ExternalDriveText.headline(move, destinationName: "MEDIA"), "Moved 238 of 240 to MEDIA")
        let trash = makeSummary(kind: .trashExisting, total: 3, succeeded: 2)
        XCTAssertEqual(ExternalDriveText.headline(trash, destinationName: "MEDIA"),
                       "Moved 2 of 3 originals to the Trash")
    }

    func testMovingLineWithAndWithoutETA() {
        var progress = ExternalDriveProgress()
        progress.unitIndex = 36
        progress.unitCount = 240
        XCTAssertEqual(ExternalDriveText.movingLine(progress, done: "1 GB", total: "9 GB", remaining: "4 min"),
                       "File 37 of 240 · 1 GB of 9 GB · about 4 min left")
        XCTAssertEqual(ExternalDriveText.movingLine(progress, done: "1 GB", total: "9 GB", remaining: nil),
                       "File 37 of 240 · 1 GB of 9 GB")
    }

    func testMoveActionChecksAgainWhenNothingIsReady() {
        let review = makeReview([.needsOrganizing])
        XCTAssertEqual(
            ExternalDriveText.moveAction(review, preflight: .ready(freeBytes: 100), destinationName: "MEDIA",
                                         formatBytes: { "\($0) B" }),
            .checkAgain
        )
    }

    func testMoveActionRefusesWhenTheFilesDontFit() {
        let review = makeReview([.ready, .ready], byteCount: 60)
        XCTAssertEqual(
            ExternalDriveText.moveAction(review, preflight: .ready(freeBytes: 100), destinationName: "MEDIA",
                                         formatBytes: { "\($0) B" }),
            .notice("Not enough space on MEDIA: 120 B to move, 100 B free.")
        )
    }

    func testMoveActionConfirmsTheReadyFileCount() {
        let review = makeReview([.ready, .ready, .notMedia], byteCount: 50)
        XCTAssertEqual(
            ExternalDriveText.moveAction(review, preflight: .ready(freeBytes: 100), destinationName: "MEDIA",
                                         formatBytes: { "\($0) B" }),
            .confirm(fileCount: 2)
        )
    }

    func testEnsuringTheLogFileCreatesItWithoutWritingALine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveText-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Logs/external-drive.log")
        let log = ExternalDriveLog(fileURL: file)
        log.ensureFileExists()
        XCTAssertEqual(try Data(contentsOf: file), Data())
        log.append("kept")
        log.ensureFileExists()
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasSuffix("  kept\n"))
    }

    // MARK: Helpers

    private func makeReview(_ buckets: [ExternalDriveBucket], byteCount: Int64 = 10) -> ExternalDriveReview {
        let entries = buckets.enumerated().map { index, bucket in
            ExternalDriveEntry(relativePath: "2024/\(index).jpg", bucket: bucket, reason: nil, note: nil,
                               byteCount: byteCount)
        }
        let ready = entries.filter { $0.bucket == .ready }
            .map { ExternalDriveUnit(relativePaths: [$0.relativePath], byteCount: $0.byteCount) }
        let existing = entries.filter { $0.bucket == .alreadyOnDestination }
            .map { ExternalDriveUnit(relativePaths: [$0.relativePath], byteCount: $0.byteCount) }
        return ExternalDriveReview(entries: entries, readyUnits: ready, existingUnits: existing)
    }

    private func makeSummary(kind: ExternalDriveRunSummary.Kind, total: Int, succeeded: Int)
        -> ExternalDriveRunSummary {
        ExternalDriveRunSummary(kind: kind, totalUnits: total, attemptedUnits: total, succeededUnits: succeeded,
                                results: [], notAttempted: [], wasCancelled: false, stoppedReason: nil)
    }
}
