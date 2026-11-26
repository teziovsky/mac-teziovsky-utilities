import CoreGraphics
import ImageIO
import Photos
@testable import TeziovskyUtilities
import XCTest

final class PhotoAssetExportPlanTests: XCTestCase {
    func testUnmodifiedOriginalIsPrimaryWhenEditsAreNotRequested() {
        let plan = PhotoAssetExporter.resourcePlan(
            available: [.photo, .fullSizePhoto, .adjustmentData],
            mediaType: .image,
            preferEdited: false,
            includeCompanions: true
        )

        XCTAssertEqual(plan?.primary, .photo)
    }

    func testEditedRenderIsPrimaryWhenRequested() {
        let plan = PhotoAssetExporter.resourcePlan(
            available: [.photo, .fullSizePhoto, .adjustmentData],
            mediaType: .image,
            preferEdited: true,
            includeCompanions: true
        )

        XCTAssertEqual(plan?.primary, .fullSizePhoto)
    }

    func testLivePhotoMotionIsExportedWithTheStill() {
        let plan = PhotoAssetExporter.resourcePlan(
            available: [.photo, .pairedVideo],
            mediaType: .image,
            preferEdited: true,
            includeCompanions: true
        )

        XCTAssertEqual(plan, PhotoExportResourcePlan(primary: .photo, companions: [.pairedVideo]))
    }

    func testEditedLivePhotoUsesEditedMotion() {
        let plan = PhotoAssetExporter.resourcePlan(
            available: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo],
            mediaType: .image,
            preferEdited: true,
            includeCompanions: true
        )

        XCTAssertEqual(plan, PhotoExportResourcePlan(primary: .fullSizePhoto, companions: [.fullSizePairedVideo]))
    }

    func testRAWPlusJPEGKeepsTheRAWAlternate() {
        let plan = PhotoAssetExporter.resourcePlan(
            available: [.photo, .alternatePhoto],
            mediaType: .image,
            preferEdited: false,
            includeCompanions: true
        )

        XCTAssertEqual(plan, PhotoExportResourcePlan(primary: .photo, companions: [.alternatePhoto]))
    }

    func testCompanionsCanBeDisabled() {
        let plan = PhotoAssetExporter.resourcePlan(
            available: [.photo, .pairedVideo, .alternatePhoto],
            mediaType: .image,
            preferEdited: false,
            includeCompanions: false
        )

        XCTAssertEqual(plan, PhotoExportResourcePlan(primary: .photo, companions: []))
    }

    func testVideoPrefersOriginalUnlessEditsRequested() {
        XCTAssertEqual(
            PhotoAssetExporter.resourcePlan(
                available: [.video, .fullSizeVideo],
                mediaType: .video,
                preferEdited: false,
                includeCompanions: true
            )?.primary,
            .video
        )
        XCTAssertEqual(
            PhotoAssetExporter.resourcePlan(
                available: [.video, .fullSizeVideo],
                mediaType: .video,
                preferEdited: true,
                includeCompanions: true
            )?.primary,
            .fullSizeVideo
        )
    }

    func testCompanionNameFollowsThePrimaryDestination() {
        let primary = URL(fileURLWithPath: "/export/IMG_0001 (1).HEIC")

        XCTAssertEqual(
            PhotoAssetExporter.companionFilename(
                primaryDestination: primary,
                companionOriginalFilename: "IMG_0001.MOV"
            ),
            "IMG_0001 (1).MOV"
        )
    }
}

final class PhotoAssetExportFinalizationTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportFinalization-\(UUID().uuidString).jpg")
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for index in 0..<(64 * 48 * 4) {
            pixels[index] = UInt8(truncatingIfNeeded: index &* 37)
        }
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2019:08:10 09:15:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:00"
            ]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testFinalizingAnExportedOriginalLeavesItsBytesUntouched() throws {
        let before = try Data(contentsOf: url)

        try PhotoAssetExporter.finalizeExportedFile(
            at: url,
            info: ExportedResourceInfo(creationDate: Date(timeIntervalSince1970: 1_600_000_000), modificationDate: nil)
        )

        XCTAssertEqual(try Data(contentsOf: url), before, "An exported original must stay byte-identical")
    }

    func testFinalizingSetsFinderCreatedToTheExifCaptureTime() throws {
        try PhotoAssetExporter.finalizeExportedFile(
            at: url,
            info: ExportedResourceInfo(creationDate: Date(timeIntervalSince1970: 1_600_000_000), modificationDate: nil)
        )

        let created = try XCTUnwrap(url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        // 09:15 at UTC+2 is 07:15 UTC on 10 August 2019.
        XCTAssertEqual(created.timeIntervalSince1970, 1_565_421_300, accuracy: 1)
    }
}
