import CoreGraphics
import Foundation
import ImageIO
@testable import TeziovskyUtilities
import XCTest

/// Applying a previewed move re-plans the file on fresh dates; it must agree with the preview
/// even when an embedded date, not the oldest date overall, decided the year.
final class LocalMediaOrganizerMoveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMediaOrganizerMove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testEmbeddedDateMovesFileOutOfYearFolderDespiteOlderFileSystemDate() async throws {
        let source = try makeJPEG("X/2019/a.jpg", exifDate: "2023:02:09 12:00:00", fileDate: date(2019, 6, 1))
        let item = try await plannedMove(source, relativePath: "X/2019/a.jpg")
        XCTAssertEqual(item.destinationRelativePath, "X/2023/a.jpg")

        try await LocalMediaOrganizer.move(item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("X/2023/a.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testPhotoLeavesVideoFolderWhenFileSystemDateIsOlder() async throws {
        let source = try makeJPEG("2024/_Filmy/photo.jpg", exifDate: "2024:06:01 12:00:00", fileDate: date(2023, 3, 1))
        let item = try await plannedMove(source, relativePath: "2024/_Filmy/photo.jpg")
        XCTAssertEqual(item.destinationRelativePath, "2024/photo.jpg")

        try await LocalMediaOrganizer.move(item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2024/photo.jpg").path))
    }

    func testMoveIsRejectedWhenDatesChangedSincePreview() async throws {
        let source = try makeJPEG("a.jpg", exifDate: nil, fileDate: date(2020, 6, 1))
        let item = try await plannedMove(source, relativePath: "a.jpg")
        XCTAssertEqual(item.destinationRelativePath, "2020/a.jpg")
        try FileDatePreservation.applyFileDates(to: source, created: date(2018, 6, 1), modified: date(2018, 6, 1))

        do {
            try await LocalMediaOrganizer.move(item)
            XCTFail("Expected the move to reject changed dates")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Dates changed"), error.localizedDescription)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    // MARK: - Helpers

    private func plannedMove(_ url: URL, relativePath: String) async throws -> LocalMediaOrganizationItem {
        let evidence = try await MediaMetadataReader.readDateEvidence(url: url, isVideo: false)
        let outcome = LocalMediaOrganizationPlanner.plan(
            fileURL: url,
            relativePath: relativePath,
            rootDirectory: root,
            evidence: evidence,
            isVideo: false
        )
        guard case .move(let item) = outcome else {
            XCTFail("Expected a planned move, got \(outcome) from \(evidence)")
            throw CocoaError(.fileReadUnknown)
        }
        return item
    }

    private func makeJPEG(_ relativePath: String, exifDate: String?, fileDate: Date) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [:]
        if let exifDate {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate]
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileDatePreservation.applyFileDates(to: url, created: fileDate, modified: fileDate)
        return url
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
