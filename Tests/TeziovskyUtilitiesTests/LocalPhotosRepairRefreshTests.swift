import CoreGraphics
import ImageIO
@testable import TeziovskyUtilities
import XCTest

/// Repairing dates rewrites the dates the Organize step decides on, so the preview must be
/// rebuilt from disk afterwards.
@MainActor
final class LocalPhotosRepairRefreshTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPhotosRepairRefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testRepairRefreshesTheOrganizePreview() async throws {
        // EXIF says 2017, but the file system remembers 2014: the repair rewrites EXIF to 2014.
        try makeJPEG("2015/a.jpg", exifDate: "2017:06:15 12:00:00", fileDate: date(2014, 3, 10))
        let service = LocalPhotosService()
        service.scan(directory: root)
        try await waitUntilIdle(service)
        XCTAssertEqual(service.organizationItems.map(\.destinationRelativePath), ["2017/a.jpg"])
        XCTAssertEqual(service.pendingItems.map(\.relativePath), ["2015/a.jpg"])

        service.repairAll()
        try await waitUntilIdle(service)

        XCTAssertEqual(service.repairedIDs, ["2015/a.jpg"])
        XCTAssertEqual(service.organizationItems.map(\.destinationRelativePath), ["2014/a.jpg"])
        XCTAssertTrue(service.failures.isEmpty, "\(service.failures)")
    }

    // MARK: - Helpers

    private func waitUntilIdle(_ service: LocalPhotosService) async throws {
        let deadline = Date().addingTimeInterval(30)
        try await Task.sleep(nanoseconds: 20_000_000)
        while service.isRunning {
            guard Date() < deadline else { return XCTFail("Service did not finish") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func makeJPEG(_ relativePath: String, exifDate: String, fileDate: Date) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileDatePreservation.applyFileDates(to: url, created: fileDate, modified: fileDate)
    }
}
