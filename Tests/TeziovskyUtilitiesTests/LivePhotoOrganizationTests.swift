import AVFoundation
import CoreGraphics
import ImageIO
@testable import TeziovskyUtilities
import XCTest

/// A Live Photo is a still plus a short MOV with the same name; organizing must keep them together.
final class LivePhotoOrganizationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePhotoOrganization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testDetectsMotionFilesSharingDirectoryAndBaseNameWithAStill() {
        let companions = LocalMediaOrganizationPlanner.livePhotoCompanions(in: [
            "trip/IMG_0001.HEIC",
            "trip/IMG_0001.MOV",
            "trip/IMG_0002.mov",
            "other/IMG_0001.MOV",
            "trip/clip.mp4",
            "trip/img_0002.jpg"
        ])

        XCTAssertEqual(companions, [
            "trip/IMG_0001.MOV": "trip/IMG_0001.HEIC",
            "trip/IMG_0002.mov": "trip/img_0002.jpg"
        ])
    }

    func testMotionFileIsPlacedWithPhotosInsteadOfFilmy() {
        let item = LocalMediaOrganizationPlanner.makeCandidate(
            fileURL: root.appendingPathComponent("IMG_0001.MOV"),
            relativePath: "IMG_0001.MOV",
            rootDirectory: root,
            evidence: [FileDateEvidence(source: .containerCreation, date: date(2019, 7, 1))],
            isVideo: true,
            groupsWithPhotos: true,
            now: date(2026, 1, 1)
        )

        XCTAssertEqual(item?.destinationRelativePath, "2019/IMG_0001.MOV")
        XCTAssertEqual(item?.isVideo, true)
    }

    func testRenamedStillTakesItsMotionFileAlong() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("2019"),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("2019/IMG_0001.HEIC"))
        let candidates = [
            candidate("IMG_0001.HEIC", isVideo: false),
            candidate("IMG_0001.MOV", isVideo: true)
        ]

        let items = LocalMediaOrganizationPlanner.resolveCollisions(
            candidates,
            rootDirectory: root,
            livePhotoCompanions: ["IMG_0001.MOV": "IMG_0001.HEIC"]
        )

        XCTAssertEqual(
            items.map(\.destinationRelativePath).sorted(),
            ["2019/IMG_0001 (1).HEIC", "2019/IMG_0001 (1).MOV"]
        )
    }

    func testScanKeepsALivePhotoPairInTheSameYearFolder() async throws {
        try makeJPEG(named: "IMG_0001.JPG", exifDate: "2019:07:01 12:00:00")
        try await TestVideoFactory.makeVideo(
            at: root.appendingPathComponent("IMG_0001.MOV"),
            seconds: 1,
            metadata: [TestVideoFactory.creationDateItem(date(2019, 7, 1, hour: 12))]
        )

        let result = try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: ["jpg", "mov"],
            progress: { _ in }
        )

        XCTAssertEqual(
            result.organizationItems.map(\.destinationRelativePath).sorted(),
            ["2019/IMG_0001.JPG", "2019/IMG_0001.MOV"]
        )
    }

    // MARK: - Helpers

    private func candidate(_ name: String, isVideo: Bool) -> LocalMediaOrganizationItem {
        LocalMediaOrganizationItem(
            sourceURL: root.appendingPathComponent(name),
            sourceRelativePath: name,
            destinationURL: root.appendingPathComponent("2019/\(name)"),
            destinationRelativePath: "2019/\(name)",
            proposedDate: date(2019, 7, 1),
            proposedSource: .exifOriginal,
            isVideo: isVideo,
            destinationWasRenamed: false,
            rootDirectory: root,
            groupsWithPhotos: false
        )
    }

    private func makeJPEG(named name: String, exifDate: String) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
