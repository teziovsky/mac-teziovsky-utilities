import CoreGraphics
import ImageIO
@testable import TeziovskyUtilities
import XCTest

/// Guards the "never re-encode pixels" contract and the EXIF time-zone contract of date repair.
final class ImageMetadataIntegrityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageMetadataIntegrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Pixel integrity

    func testSynchronizingJPEGDatesKeepsPixelsIdentical() throws {
        try assertSynchronizationKeepsPixels(pathExtension: "jpg", uti: "public.jpeg")
    }

    func testSynchronizingHEICDatesKeepsPixelsIdentical() throws {
        try assertSynchronizationKeepsPixels(pathExtension: "heic", uti: "public.heic")
    }

    func testSynchronizingKeepsLocationCameraAndOrientation() throws {
        for (name, uti) in [("tagged.jpg", "public.jpeg"), ("tagged.heic", "public.heic")] {
            let url = try makeNoisyImage(
                named: name,
                uti: uti,
                exif: [kCGImagePropertyExifDateTimeOriginal: "2012:06:15 12:30:00"],
                extra: [
                    kCGImagePropertyGPSDictionary: [
                        kCGImagePropertyGPSLatitude: 50.06,
                        kCGImagePropertyGPSLatitudeRef: "N",
                        kCGImagePropertyGPSLongitude: 19.94,
                        kCGImagePropertyGPSLongitudeRef: "E"
                    ],
                    kCGImagePropertyTIFFDictionary: [
                        kCGImagePropertyTIFFMake: "Apple",
                        kCGImagePropertyTIFFModel: "iPhone 15 Pro"
                    ],
                    kCGImagePropertyOrientation: 6
                ]
            )

            try FileDatePreservation.synchronizeImageCreationDates(in: url, to: utc("2004-03-04T05:06:07Z"))

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude] as? Double ?? 0, 50.06, accuracy: 0.001, name)
            XCTAssertEqual(gps?[kCGImagePropertyGPSLongitudeRef] as? String, "E", name)
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "iPhone 15 Pro", name)
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6, name)
        }
    }

    // MARK: - Time zones

    func testReadingEvidenceHonorsExifOffset() async throws {
        let url = try makeNoisyImage(
            named: "tokyo.jpg",
            uti: "public.jpeg",
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00"
            ]
        )

        let evidence = try await MediaMetadataReader.readDateEvidence(url: url, isVideo: false)
        let original = try XCTUnwrap(evidence.first { $0.source == .exifOriginal }?.date)

        // 10:00 in UTC+9 is 01:00 UTC.
        XCTAssertEqual(original, utc("2024-05-01T01:00:00Z"))
    }

    func testSynchronizingKeepsExistingOffsetAndWritesLocalTimeInThatOffset() throws {
        let url = try makeNoisyImage(
            named: "tokyo.jpg",
            uti: "public.jpeg",
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00"
            ]
        )

        // 23:00 UTC on 30 April is 08:00 on 1 May in UTC+9.
        try FileDatePreservation.synchronizeImageCreationDates(in: url, to: utc("2024-04-30T23:00:00Z"))

        let exif = try exifDictionary(of: url)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:05:01 08:00:00")
        XCTAssertEqual(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String, "+09:00")
    }

    func testSynchronizingDoesNotAddOffsetFieldsThatWereAbsent() throws {
        let url = try makeNoisyImage(
            named: "plain.jpg",
            uti: "public.jpeg",
            exif: [kCGImagePropertyExifDateTimeOriginal: "2012:06:15 12:30:00"]
        )

        try FileDatePreservation.synchronizeImageCreationDates(in: url, to: utc("2004-03-04T05:06:07Z"))

        let exif = try exifDictionary(of: url)
        XCTAssertNotNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifOffsetTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifOffsetTime])
    }

    // MARK: - Helpers

    private func assertSynchronizationKeepsPixels(
        pathExtension: String,
        uti: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try makeNoisyImage(
            named: "noise.\(pathExtension)",
            uti: uti,
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2012:06:15 12:30:00",
                kCGImagePropertyExifDateTimeDigitized: "2011:06:15 12:30:00"
            ]
        )
        let before = try decodedPixels(of: url)

        try FileDatePreservation.synchronizeImageCreationDates(in: url, to: utc("2004-03-04T05:06:07Z"))

        let after = try decodedPixels(of: url)
        XCTAssertEqual(after.count, before.count, file: file, line: line)
        XCTAssertTrue(after == before, "Date repair re-encoded the \(pathExtension) pixels", file: file, line: line)
        let exif = try exifDictionary(of: url)
        XCTAssertNotEqual(
            exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            "2012:06:15 12:30:00",
            "The date itself must still be rewritten",
            file: file,
            line: line
        )
    }

    private func makeNoisyImage(
        named name: String,
        uti: String,
        exif: [CFString: Any],
        extra: [CFString: Any] = [:]
    ) throws -> URL {
        let width = 128
        let height = 96
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 0x1234_5678
        for index in 0..<(width * height * 4) {
            seed = seed &* 1_103_515_245 &+ 12_345
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw XCTSkip("\(uti) encoding is unavailable on this host")
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: exif
        ]
        properties.merge(extra) { current, _ in current }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("\(uti) encoding is unavailable on this host")
        }
        return url
    }

    private func decodedPixels(of url: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func exifDictionary(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    }

    private func utc(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }
}
