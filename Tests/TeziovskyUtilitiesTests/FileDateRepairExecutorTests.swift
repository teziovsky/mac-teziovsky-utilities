import CoreGraphics
import ImageIO
@testable import TeziovskyUtilities
import XCTest

final class FileDateRepairExecutorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDateRepairExecutor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testRepairSetsFinderDatesToTheCaptureTimeAndLeavesNoBackup() async throws {
        let url = root.appendingPathComponent("photo.jpg")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2015:06:15 14:30:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:00"
            ]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let evidence = try await MediaMetadataReader.readDateEvidence(url: url, isVideo: false)
        let item = try XCTUnwrap(FileDateRepairPlanner.makeItem(
            fileURL: url,
            relativePath: "photo.jpg",
            evidence: evidence
        ))

        try await FileDateRepairExecutor.repair(item)

        // 14:30 at UTC+2 is 12:30 UTC.
        let captured = Date(timeIntervalSince1970: 1_434_371_400)
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        XCTAssertEqual(try XCTUnwrap(values.creationDate).timeIntervalSince(captured), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(values.contentModificationDate).timeIntervalSince(captured), 0, accuracy: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["photo.jpg"])
    }
}
