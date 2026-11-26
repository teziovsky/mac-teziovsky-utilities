import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TeziovskyUtilities

final class LocalMediaConversionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMediaConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testPlansHEICToJPEGWithOriginalRetentionSetting() async throws {
        let source = root.appendingPathComponent("photo.heic")
        try Data().write(to: source)
        let item = await LocalMediaConversionPlanner.makeCandidate(
            fileURL: source,
            relativePath: "photo.heic",
            rootDirectory: root,
            config: LocalMediaConversionConfig(keepOriginals: false, videoOutputContainer: .mp4)
        )

        XCTAssertEqual(item?.destinationRelativePath, "photo.jpg")
        XCTAssertEqual(item?.kind, .heicToJPEG)
        XCTAssertEqual(item?.keepOriginal, false)
    }

    func testSkipsConversionsDisabledInSettings() async throws {
        let source = root.appendingPathComponent("photo.heic")
        try Data().write(to: source)
        let item = await LocalMediaConversionPlanner.makeCandidate(
            fileURL: source,
            relativePath: "photo.heic",
            rootDirectory: root,
            config: LocalMediaConversionConfig(
                convertHEIC: false,
                keepOriginals: true,
                videoOutputContainer: .mp4
            )
        )

        XCTAssertNil(item)
    }

    func testPlannedConversionsThatShareADestinationGetDistinctNames() async throws {
        let legacy = root.appendingPathComponent("clip.mov")
        let rewrapped = root.appendingPathComponent("clip.m4v")
        try await TestVideoFactory.makeVideo(at: legacy, seconds: 1, fileType: .mov, codec: .jpeg)
        try await TestVideoFactory.makeVideo(at: rewrapped, seconds: 1, fileType: .m4v)
        let config = LocalMediaConversionConfig(keepOriginals: true, videoOutputContainer: .mp4)
        var candidates: [LocalMediaConversionItem] = []
        for (url, name) in [(legacy, "clip.mov"), (rewrapped, "clip.m4v")] {
            let planned = await LocalMediaConversionPlanner.makeCandidate(
                fileURL: url,
                relativePath: name,
                rootDirectory: root,
                config: config
            )
            candidates.append(try XCTUnwrap(planned, name))
        }

        let items = LocalMediaConversionPlanner.resolveCollisions(candidates, rootDirectory: root)

        XCTAssertEqual(items.map(\.sourceRelativePath), ["clip.m4v", "clip.mov"])
        XCTAssertEqual(items.map(\.destinationRelativePath), ["clip.mp4", "clip (1).mp4"])
        XCTAssertEqual(items.map(\.kind), [.remuxVideo(.mp4), .legacyVideo(.mp4, .h264)])
        XCTAssertEqual(items.map(\.destinationWasRenamed), [false, true])
    }

    func testConvertsHEICToVerifiedJPEGBeforeRemovingOriginal() async throws {
        let source = root.appendingPathComponent("photo.heic")
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  source as CFURL,
                  "public.heic" as CFString,
                  1,
                  nil
              ) else {
            throw XCTSkip("HEIC encoding is unavailable on this host")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("HEIC encoding is unavailable on this host")
        }

        let plannedItem = await LocalMediaConversionPlanner.makeCandidate(
            fileURL: source,
            relativePath: "photo.heic",
            rootDirectory: root,
            config: LocalMediaConversionConfig(keepOriginals: false, videoOutputContainer: .mp4)
        )
        let item = try XCTUnwrap(plannedItem)
        try await LocalMediaConverter.convert(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.destinationURL.path))
        let converted = try XCTUnwrap(CGImageSourceCreateWithURL(item.destinationURL as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(converted), 0)
    }
}
