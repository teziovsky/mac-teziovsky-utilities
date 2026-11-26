import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TeziovskyUtilities

final class FileDateRepairPlannerTests: XCTestCase {
    func testChoosesOldestValidNonCreationDateAndReportsSource() {
        let created = date(2024)
        let modified = date(2015)
        let exif = date(2005)
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: created),
                FileDateEvidence(source: .filesystemModification, date: modified),
                FileDateEvidence(source: .exifOriginal, date: exif)
            ],
            now: date(2026)
        )

        XCTAssertEqual(item?.proposedDate, exif)
        XCTAssertEqual(item?.proposedSource, .exifOriginal)
        XCTAssertEqual(item?.currentCreationDate, created)
        XCTAssertEqual(item?.newestDisagreeingDate, created)
    }

    func testDoesNotProposeDateWithinTolerance() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let modified = created.addingTimeInterval(-0.5)
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: created),
                FileDateEvidence(source: .filesystemModification, date: modified)
            ],
            now: date(2026)
        )

        XCTAssertNil(item)
    }

    func testChoosesOldestOfAllCreationFields() {
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2024)),
                FileDateEvidence(source: .exifOriginal, date: date(2012)),
                FileDateEvidence(source: .exifDigitized, date: date(2010)),
                FileDateEvidence(source: .tiffDateTime, date: date(2008)),
                FileDateEvidence(source: .filesystemModification, date: date(2015))
            ],
            now: date(2026)
        )

        XCTAssertEqual(item?.proposedDate, date(2008))
        XCTAssertEqual(item?.proposedSource, .tiffDateTime)
    }

    func testRepairsImplausibleFutureCreationDateUsingOldestValidDate() {
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2024)),
                FileDateEvidence(source: .exifOriginal, date: date(2030))
            ],
            now: date(2026)
        )

        XCTAssertEqual(item?.proposedDate, date(2024))
        XCTAssertEqual(item?.proposedSource, .filesystemCreation)
    }

    func testRepairsEmbeddedDatesWhenFilesystemCreationIsAlreadyOldest() {
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2005)),
                FileDateEvidence(source: .exifOriginal, date: date(2012)),
                FileDateEvidence(source: .exifDigitized, date: date(2010)),
                FileDateEvidence(source: .filesystemModification, date: date(2024))
            ],
            now: date(2026)
        )

        XCTAssertEqual(item?.proposedDate, date(2005))
        XCTAssertEqual(item?.proposedSource, .filesystemCreation)
        XCTAssertEqual(item?.newestDisagreeingDate, date(2024))
    }

    func testDoesNotRepairWhenAllDatesAlreadyMatch() {
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2005)),
                FileDateEvidence(source: .exifOriginal, date: date(2005)),
                FileDateEvidence(source: .tiffDateTime, date: date(2005)),
                FileDateEvidence(source: .filesystemModification, date: date(2005))
            ],
            now: date(2026)
        )

        XCTAssertNil(item)
    }

    func testRepairsWhenOnlyModificationDateDiffers() {
        let item = FileDateRepairPlanner.makeItem(
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            relativePath: "photo.jpg",
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2005)),
                FileDateEvidence(source: .exifOriginal, date: date(2005)),
                FileDateEvidence(source: .tiffDateTime, date: date(2005)),
                FileDateEvidence(source: .filesystemModification, date: date(2024))
            ],
            now: date(2026)
        )

        XCTAssertEqual(item?.proposedDate, date(2005))
        XCTAssertEqual(item?.proposedSource, .filesystemCreation)
        XCTAssertEqual(item?.newestDisagreeingDate, date(2024))
    }

    func testEmbeddedSyncSkippedWhenEmbeddedDatesAlreadyMatchTarget() {
        let target = date(2015)
        XCTAssertFalse(
            FileDateRepairPlanner.embeddedCreationDatesNeedSync(
                [
                    FileDateEvidence(source: .filesystemCreation, date: date(2026)),
                    FileDateEvidence(source: .filesystemModification, date: target),
                    FileDateEvidence(source: .exifOriginal, date: target),
                    FileDateEvidence(source: .exifDigitized, date: target)
                ],
                target: target
            )
        )
        XCTAssertTrue(
            FileDateRepairPlanner.embeddedCreationDatesNeedSync(
                [
                    FileDateEvidence(source: .filesystemCreation, date: date(2026)),
                    FileDateEvidence(source: .filesystemModification, date: target),
                    FileDateEvidence(source: .exifOriginal, date: date(2012))
                ],
                target: target
            )
        )
    }

    private func date(_ year: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1))!
    }
}

final class FileDateRepairExtensionTests: XCTestCase {
    func testNormalizesFlexibleExtensionList() {
        let value = FileDateRepairExtensions.normalizedString(" .JPG, heic;MOV\njpg ")

        XCTAssertEqual(value, "heic, jpg, mov")
        XCTAssertTrue(
            FileDateRepairExtensions.supports(
                URL(fileURLWithPath: "/tmp/PHOTO.JPG"),
                extensions: FileDateRepairExtensions.parse(value)
            )
        )
    }

    func testChunkerSkipsAttemptedItems() {
        let items = (1...5).map(makeItem)
        let chunk = FileDateRepairChunker.next(
            from: items,
            attemptedIDs: [items[0].id, items[2].id],
            size: 2
        )

        XCTAssertEqual(chunk.map(\.id), [items[1].id, items[3].id])
    }

    private func makeItem(_ index: Int) -> FileDateRepairItem {
        FileDateRepairItem(
            relativePath: "\(index).jpg",
            fileURL: URL(fileURLWithPath: "/tmp/\(index).jpg"),
            currentCreationDate: Date(timeIntervalSince1970: 200),
            proposedDate: Date(timeIntervalSince1970: 100),
            proposedSource: .filesystemModification,
            evidence: []
        )
    }
}

final class FileDateRepairScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDateRepairTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSkipsHiddenPackagesSymlinksAndUnsupportedFiles() async throws {
        try makeRepairCandidate("visible.jpg")
        try makeRepairCandidate(".hidden.jpg")
        try makeRepairCandidate("notes.txt")

        let hiddenDirectory = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try makeRepairCandidate(".hidden/inside.jpg")

        let package = root.appendingPathComponent("Archive.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try makeRepairCandidate("Archive.app/inside.jpg")

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.jpg"),
            withDestinationURL: root.appendingPathComponent("visible.jpg")
        )

        let result = try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )
        let visibleURL = root.appendingPathComponent("visible.jpg")
        let evidence = try await MediaMetadataReader.readDateEvidence(url: visibleURL, isVideo: false)
        let directCandidate = LocalMediaOrganizationPlanner.makeCandidate(
            fileURL: visibleURL,
            relativePath: "visible.jpg",
            rootDirectory: root,
            evidence: evidence,
            isVideo: MediaFileClassifier.isVideo(visibleURL.lastPathComponent)
        )

        XCTAssertEqual(result.scannedFileCount, 1)
        XCTAssertEqual(result.items.map(\.relativePath), ["visible.jpg"])
        XCTAssertNotNil(directCandidate, "Evidence: \(evidence), root: \(root.path)")
        XCTAssertEqual(result.organizationItems.map(\.sourceRelativePath), ["visible.jpg"])
        XCTAssertEqual(result.organizationSkippedCount, 0)
    }

    func testScanHonorsCancellation() async throws {
        for index in 0..<100 {
            try makeRepairCandidate("\(index).jpg")
        }

        let task = Task {
            try await FileDateRepairScanner.scan(
                directory: root,
                supportedExtensions: ["jpg"],
                progress: { _ in }
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testScanOutputsReportsUndatedFileAsHavingNoUsableDate() async throws {
        try makeRepairCandidate("undated.jpg", exifDate: nil)
        let sentinel = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes(
            [.creationDate: sentinel, .modificationDate: sentinel],
            ofItemAtPath: root.appendingPathComponent("undated.jpg").path
        )

        let result = try await FileDateRepairScanner.scanOutputs(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )

        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertFalse(output.hasUsableDate)
        XCTAssertTrue(output.isAlreadyOrganized)
    }

    func testScanOutputsReportsOutsideYear() async throws {
        let yearFolder = root.appendingPathComponent("2025", isDirectory: true)
        try makeRepairCandidate("2025/old.jpg", exifDate: "2024:06:01 12:00:00")
        let taken = Date(timeIntervalSince1970: 1_717_243_200)
        try FileManager.default.setAttributes(
            [.creationDate: taken, .modificationDate: taken],
            ofItemAtPath: yearFolder.appendingPathComponent("old.jpg").path
        )

        let result = try await FileDateRepairScanner.scanOutputs(
            directory: yearFolder,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )

        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertTrue(output.hasUsableDate)
        XCTAssertEqual(output.outsideScannedFolderYear, "2024")
        XCTAssertFalse(output.notices.isEmpty)
    }

    func testScanAggregatesTheSameAsBefore() async throws {
        try makeRepairCandidate("2005/2005 Trip/organized.jpg")
        try makeRepairCandidate("loose.jpg")

        let result = try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )

        XCTAssertEqual(result.scannedFileCount, 2)
        XCTAssertEqual(result.organizationItems.count, 1)
        XCTAssertEqual(result.organizationSkippedCount, 1)
    }

    private func makeRepairCandidate(_ relativePath: String, exifDate: String? = "2005:01:01 00:00:00") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [:]
        if let exifDate {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

final class FileDateRepairVerificationTests: XCTestCase {
    func testAllowsDroppedEmbeddedSourcesWhenRemainingDatesMatch() {
        let target = Date(timeIntervalSince1970: 1_000)
        let failure = FileDateRepairVerification.validate(
            [
                FileDateEvidence(source: .filesystemCreation, date: target),
                FileDateEvidence(source: .filesystemModification, date: target),
                FileDateEvidence(source: .exifOriginal, date: target)
            ],
            expectedEmbeddedSources: [.exifOriginal, .tiffDateTime],
            target: target
        )

        XCTAssertNil(failure)
    }

    func testRejectsStaleEmbeddedDate() {
        let target = Date(timeIntervalSince1970: 1_000)
        let failure = FileDateRepairVerification.validate(
            [
                FileDateEvidence(source: .filesystemCreation, date: target),
                FileDateEvidence(source: .filesystemModification, date: target),
                FileDateEvidence(source: .exifOriginal, date: Date(timeIntervalSince1970: 500))
            ],
            expectedEmbeddedSources: [.exifOriginal],
            target: target
        )

        XCTAssertEqual(failure, .embeddedDateMismatch(.exifOriginal))
    }

    func testRejectsCompleteLossOfEmbeddedDates() {
        let target = Date(timeIntervalSince1970: 1_000)
        let failure = FileDateRepairVerification.validate(
            [
                FileDateEvidence(source: .filesystemCreation, date: target),
                FileDateEvidence(source: .filesystemModification, date: target)
            ],
            expectedEmbeddedSources: [.exifOriginal],
            target: target
        )

        XCTAssertEqual(failure, .embeddedDatesMissing)
    }

    func testRejectsStaleModificationDate() {
        let target = Date(timeIntervalSince1970: 1_000)
        let failure = FileDateRepairVerification.validate(
            [
                FileDateEvidence(source: .filesystemCreation, date: target),
                FileDateEvidence(source: .filesystemModification, date: Date(timeIntervalSince1970: 2_000))
            ],
            expectedEmbeddedSources: [],
            target: target
        )

        XCTAssertEqual(failure, .modificationDateMismatch)
    }
}
