import AVFoundation
import CoreGraphics
import ImageIO
@testable import TeziovskyUtilities
import XCTest

final class YearFolderPlanningTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("YearFolderPlanning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testFileThatBelongsOutsideTheScannedFolderIsReportedNotCountedAsOrganized() async throws {
        let root = base.appendingPathComponent("2020/Wakacje", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeJPEG(at: root.appendingPathComponent("IMG_0001.JPG"), exifDate: "2018:07:01 12:00:00")

        let result = try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )

        XCTAssertTrue(result.organizationItems.isEmpty)
        XCTAssertEqual(result.organizationSkippedCount, 0, "It is not organized; it is in the 2020 folder")
        let failure = try XCTUnwrap(result.failures.first { $0.relativePath == "IMG_0001.JPG" })
        XCTAssertTrue(failure.message.contains("2018"), failure.message)
    }

    func testFileInTheRightYearAboveTheScannedFolderStaysOrganized() async throws {
        let root = base.appendingPathComponent("2020/Wakacje", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeJPEG(at: root.appendingPathComponent("IMG_0002.JPG"), exifDate: "2020:07:01 12:00:00")

        let result = try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )

        XCTAssertTrue(result.organizationItems.isEmpty)
        XCTAssertEqual(result.organizationSkippedCount, 1)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
    }

    func testFourDigitFolderThatIsNotAPlausibleYearIsNotTreatedAsOne() {
        let item = LocalMediaOrganizationPlanner.makeCandidate(
            fileURL: base.appendingPathComponent("0815/photo.jpg"),
            relativePath: "0815/photo.jpg",
            rootDirectory: base,
            evidence: [FileDateEvidence(source: .exifOriginal, date: localDate(2019, 7, 1))],
            isVideo: false,
            now: localDate(2026, 1, 1)
        )

        XCTAssertEqual(item?.destinationRelativePath, "0815/2019/photo.jpg")
    }

    private func makeJPEG(at url: URL, exifDate: String) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

final class ConversionPlanningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversionPlanning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private let config = LocalMediaConversionConfig(keepOriginals: true, videoOutputContainer: .mp4)

    func testUnreadableVideoIsReportedAsUnsupportedInsteadOfPlanned() async throws {
        let source = root.appendingPathComponent("clip.mkv")
        try Data(repeating: 0x1A, count: 2_048).write(to: source)

        let plan = await LocalMediaConversionPlanner.plan(
            fileURL: source,
            relativePath: "clip.mkv",
            rootDirectory: root,
            config: config
        )

        guard case .unsupported(let reason) = plan else {
            return XCTFail("Expected .unsupported, got \(plan)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testModernCodecInALegacyContainerIsRemuxedNotReEncoded() async throws {
        let source = root.appendingPathComponent("clip.m4v")
        try await TestVideoFactory.makeVideo(at: source, seconds: 2, fileType: .m4v)

        let plan = await LocalMediaConversionPlanner.plan(
            fileURL: source,
            relativePath: "clip.m4v",
            rootDirectory: root,
            config: config
        )

        guard case .convert(let item) = plan else {
            return XCTFail("Expected a conversion, got \(plan)")
        }
        XCTAssertEqual(item.kind, .remuxVideo(.mp4))
        XCTAssertEqual(item.destinationRelativePath, "clip.mp4")

        try await LocalMediaConverter.convert(item)

        let output = AVURLAsset(url: item.destinationURL)
        let track = try await XCTUnwrapAsync(try await output.loadTracks(withMediaType: .video).first)
        let description = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_H264)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Original is kept")
    }

    func testLegacyCodecIsReEncoded() async throws {
        let source = root.appendingPathComponent("clip.mov")
        try await TestVideoFactory.makeVideo(at: source, seconds: 1, fileType: .mov, codec: .jpeg)

        let plan = await LocalMediaConversionPlanner.plan(
            fileURL: source,
            relativePath: "clip.mov",
            rootDirectory: root,
            config: config
        )

        guard case .convert(let item) = plan else {
            return XCTFail("Expected a conversion, got \(plan)")
        }
        XCTAssertEqual(item.kind, .legacyVideo(.mp4, .h264))
    }

    func testHEICWithAnExistingJPEGTwinIsNotConvertedAgain() async throws {
        try Data().write(to: root.appendingPathComponent("photo.heic"))
        try Data().write(to: root.appendingPathComponent("photo.jpg"))

        let plan = await LocalMediaConversionPlanner.plan(
            fileURL: root.appendingPathComponent("photo.heic"),
            relativePath: "photo.heic",
            rootDirectory: root,
            config: config
        )

        XCTAssertEqual(plan, .notNeeded)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

final class ScanLeftoverTests: XCTestCase {
    func testScanReportsBackupsLeftByAnInterruptedRepair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanLeftovers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: root.appendingPathComponent(".date-repair-backup-1234.jpg"))
        try Data("partial".utf8).write(to: root.appendingPathComponent(".image-metadata-5678.jpg"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent(".DS_Store"))

        let result = try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: ["jpg"],
            progress: { _ in }
        )

        XCTAssertEqual(
            result.failures.map(\.relativePath).sorted(),
            [".date-repair-backup-1234.jpg", ".image-metadata-5678.jpg"]
        )
        XCTAssertEqual(result.scannedFileCount, 0)
    }
}

final class MediaFileClassifierFallbackTests: XCTestCase {
    func testKnownVideoExtensionsAreVideoEvenWithoutASystemType() {
        for ext in ["mkv", "webm", "flv", "wmv", "mts"] {
            XCTAssertTrue(MediaFileClassifier.isVideo(fileExtension: ext, type: nil), ext)
        }
        XCTAssertFalse(MediaFileClassifier.isVideo(fileExtension: "wav", type: nil))
    }
}

private func localDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}
