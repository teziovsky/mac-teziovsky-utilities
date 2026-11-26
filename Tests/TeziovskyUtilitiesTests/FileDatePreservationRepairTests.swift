import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TeziovskyUtilities

final class FileDatePreservationRepairTests: XCTestCase {
    func testAppliesCreatedAndModifiedDatesTogether() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDatePreservation-\(UUID().uuidString).jpg")
        try Data("fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2005, month: 2, day: 1))!
        try FileDatePreservation.applyFileDates(to: url, created: target, modified: target)
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let actualCreation = try XCTUnwrap(values.creationDate)
        let actualModification = try XCTUnwrap(values.contentModificationDate)
        XCTAssertEqual(actualCreation.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(actualModification.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1)
    }

    func testCreationOnlyRepairPreservesModificationDate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDatePreservation-\(UUID().uuidString).jpg")
        try Data("fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let calendar = Calendar(identifier: .gregorian)
        let modified = calendar.date(from: DateComponents(year: 2015, month: 4, day: 3))!
        let proposedCreation = calendar.date(from: DateComponents(year: 2005, month: 2, day: 1))!
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

        try FileDatePreservation.applyCreationDate(proposedCreation, to: url)

        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let actualCreation = try XCTUnwrap(values.creationDate)
        let actualModification = try XCTUnwrap(values.contentModificationDate)
        XCTAssertEqual(actualCreation.timeIntervalSince1970, proposedCreation.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(actualModification.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
    }

    func testSynchronizesAllExistingImageCreationDates() async throws {
        let url = try makeTemporaryImage(
            pathExtension: "tiff",
            uti: "public.tiff",
            properties: [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2012:01:01 00:00:00",
                    kCGImagePropertyExifDateTimeDigitized: "2010:01:01 00:00:00"
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFDateTime: "2008:01:01 00:00:00"
                ]
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let target = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2005, month: 2, day: 3, hour: 4, minute: 5, second: 6)
        )!
        try FileDatePreservation.synchronizeImageCreationDates(in: url, to: target)

        let evidence = try await MediaMetadataReader.readDateEvidence(url: url, isVideo: false)
        for source in [FileDateSource.exifOriginal, .exifDigitized, .tiffDateTime] {
            let actual = try XCTUnwrap(
                evidence.first(where: { $0.source == source })?.date,
                "Missing \(source); evidence: \(evidence)"
            )
            XCTAssertEqual(actual.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testSynchronizesJPEGCreationDatesWithoutLeavingStaleValues() async throws {
        let url = try makeTemporaryImage(
            pathExtension: "jpg",
            uti: "public.jpeg",
            properties: [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2012:06:15 12:30:00",
                    kCGImagePropertyExifDateTimeDigitized: "2011:06:15 12:30:00"
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFDateTime: "2010:06:15 12:30:00"
                ]
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let target = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2004, month: 3, day: 4, hour: 5, minute: 6, second: 7)
        )!
        try FileDatePreservation.synchronizeImageCreationDates(in: url, to: target)

        let evidence = try await MediaMetadataReader.readDateEvidence(url: url, isVideo: false)
        let embedded = evidence.filter(\.source.isEmbeddedCreationDate)
        XCTAssertFalse(embedded.isEmpty)
        for item in embedded {
            XCTAssertEqual(
                item.date.timeIntervalSince1970,
                target.timeIntervalSince1970,
                accuracy: 1,
                "Stale \(item.source) remained after sync"
            )
        }
    }

    func testRemovesStaleDigitizedWhenImageIOWillNotUpdateIt() async throws {
        let url = try makeTemporaryImage(
            pathExtension: "jpg",
            uti: "public.jpeg",
            properties: [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2015:02:22 20:45:00",
                    kCGImagePropertyExifDateTimeDigitized: "2012:01:01 00:00:00"
                ]
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let target = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2015, month: 2, day: 22, hour: 20, minute: 45)
        )!
        try FileDatePreservation.synchronizeImageCreationDates(in: url, to: target)

        let evidence = try await MediaMetadataReader.readDateEvidence(url: url, isVideo: false)
        if let digitized = evidence.first(where: { $0.source == .exifDigitized })?.date {
            XCTAssertEqual(digitized.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1)
        }
        for item in evidence where item.source.isEmbeddedCreationDate {
            XCTAssertEqual(item.date.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1)
        }
    }

    private func makeTemporaryImage(
        pathExtension: String,
        uti: String,
        properties: [CFString: Any]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDateMetadata-\(UUID().uuidString).\(pathExtension)")
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
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
