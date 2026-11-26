import CoreGraphics
import ImageIO
@testable import TeziovskyUtilities
import XCTest

final class OrganizeETATests: XCTestCase {
    func testEstimatesTheRemainingTimeFromTheAverageSoFar() {
        // 10 of 40 items in 20 s → 2 s per item → 60 s left.
        XCTAssertEqual(OrganizeETA.remaining(processed: 10, total: 40, elapsed: 20) ?? -1, 60, accuracy: 0.001)
    }

    func testStaysQuietUntilThereIsEnoughToAverage() {
        XCTAssertNil(OrganizeETA.remaining(processed: 2, total: 40, elapsed: 3))
        XCTAssertNil(OrganizeETA.remaining(processed: 40, total: 40, elapsed: 80))
    }

    func testFormatsTheRemainingTimeForPeople() {
        XCTAssertEqual(OrganizeETA.text(forRemaining: 20), "less than a minute left")
        XCTAssertEqual(OrganizeETA.text(forRemaining: 150), "about 3 min left")
        XCTAssertEqual(OrganizeETA.text(forRemaining: 2 * 3600 + 600), "about 2 h 10 min left")
    }
}

final class ThumbnailSizeBucketTests: XCTestCase {
    func testPicksTheSmallestBucketCoveringTheCellInPixels() {
        XCTAssertEqual(ThumbnailLoader.pixelBucket(forPoints: 120, scale: 2), 256)
        XCTAssertEqual(ThumbnailLoader.pixelBucket(forPoints: 200, scale: 2), 512)
        XCTAssertEqual(ThumbnailLoader.pixelBucket(forPoints: 420, scale: 2), 1024)
        XCTAssertEqual(ThumbnailLoader.pixelBucket(forPoints: 900, scale: 2), 2048)
        XCTAssertEqual(ThumbnailLoader.pixelBucket(forPoints: 3000, scale: 2), 2048)
    }
}

final class LocalMediaListFilterTests: XCTestCase {
    func testMatchesPathFragmentsIgnoringCaseAndDiacritics() {
        XCTAssertTrue(LocalMediaListFilter.matches("2019/Wakacje Łeba/IMG_0001.JPG", query: "leba"))
        XCTAssertTrue(LocalMediaListFilter.matches("2019/Wakacje Łeba/IMG_0001.JPG", query: "img_0001"))
        XCTAssertTrue(LocalMediaListFilter.matches("anything.jpg", query: "  "))
        XCTAssertFalse(LocalMediaListFilter.matches("2019/Wakacje/IMG_0001.JPG", query: "2020"))
    }
}

@MainActor
final class LocalPhotosServiceSelectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPhotosSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testACancelledScanIsNotPresentedAsAFinishedOne() async throws {
        for index in 0..<200 {
            try makeJPEG("\(index).jpg", exifDate: "2015:06:15 12:00:00")
        }
        let service = LocalPhotosService()

        service.scan(directory: root)
        service.cancel()
        try await waitUntilIdle(service)

        XCTAssertFalse(service.lastScanCompleted)
    }

    func testAFinishedScanIsMarkedComplete() async throws {
        try makeJPEG("a.jpg", exifDate: "2015:06:15 12:00:00")
        let service = LocalPhotosService()

        service.scan(directory: root)
        try await waitUntilIdle(service)

        XCTAssertTrue(service.lastScanCompleted)
    }

    func testExcludedFilesAreNotOrganized() async throws {
        try makeJPEG("keep.jpg", exifDate: "2015:06:15 12:00:00")
        try makeJPEG("move.jpg", exifDate: "2015:06:15 12:00:00")
        let service = LocalPhotosService()
        service.scan(directory: root)
        try await waitUntilIdle(service)

        service.setExcluded(true, path: "keep.jpg", in: .organization)
        service.organizeAll()
        try await waitUntilIdle(service)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2015/move.jpg").path))
        XCTAssertTrue(service.isExcluded(path: "keep.jpg", in: .organization), "Exclusion survives the rescan")
    }

    func testExcludedFilesAreNotRepairedAndNotCounted() async throws {
        try makeJPEG("skip.jpg", exifDate: "2015:06:15 12:00:00")
        try makeJPEG("fix.jpg", exifDate: "2015:06:15 12:00:00")
        let service = LocalPhotosService()
        service.scan(directory: root)
        try await waitUntilIdle(service)
        XCTAssertEqual(service.pendingItems.count, 2)

        service.setExcluded(true, path: "skip.jpg", in: .repair)
        XCTAssertEqual(service.pendingItems.map(\.relativePath), ["fix.jpg"])
        service.repairAll()
        try await waitUntilIdle(service)

        XCTAssertEqual(service.repairedIDs, ["fix.jpg"])
    }

    private func waitUntilIdle(_ service: LocalPhotosService) async throws {
        let deadline = Date().addingTimeInterval(30)
        try await Task.sleep(nanoseconds: 20_000_000)
        while service.isRunning {
            guard Date() < deadline else { return XCTFail("Service did not finish") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeJPEG(_ name: String, exifDate: String) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            root.appendingPathComponent(name) as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
