import Darwin
import Foundation
@testable import TeziovskyUtilities
import XCTest

final class FileMetadataFingerprintTests: XCTestCase {
    private var root: URL!
    private let tagsXattr = "com.apple.metadata:_kMDItemUserTags"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func setXattr(_ name: String, _ value: String, on url: URL) throws {
        let bytes = Array(value.utf8)
        let result = setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW)
        XCTAssertEqual(result, 0, "setxattr failed: errno \(errno)")
    }

    private func makeSource(_ contents: String = "hello world") throws -> URL {
        let url = root.appendingPathComponent("source.dat")
        try Data(contents.utf8).write(to: url)
        try setXattr(tagsXattr, "tag", on: url)
        try setXattr("com.apple.quarantine", "0081;00000000;Safari;", on: url)
        return url
    }

    private func makeCopy(of source: URL) throws -> URL {
        let copy = root.appendingPathComponent("copy.dat")
        XCTAssertEqual(copyfile(source.path, copy.path, nil, copyfile_flags_t(COPYFILE_ALL)), 0)
        // copyfile does not carry the birth date over and rewrites the quarantine value;
        // the mover has to restore both, so the fixture does the same.
        let sourceFingerprint = try FileMetadataFingerprint.read(source, includeContent: false)
        try FileManager.default.setAttributes([.creationDate: sourceFingerprint.creationDate],
                                              ofItemAtPath: copy.path)
        try setXattr("com.apple.quarantine", "0081;00000000;Safari;", on: copy)
        return copy
    }

    private func diffs(_ source: URL, _ copy: URL, resolution: TimeInterval = 0.000_001) throws
        -> [MetadataDifference] {
        FileMetadataFingerprint.differences(
            source: try .read(source, includeContent: true),
            destination: try .read(copy, includeContent: true),
            timeResolution: resolution
        )
    }

    func testIdenticalCopyHasNoDifferences() throws {
        let source = try makeSource()
        let copy = try makeCopy(of: source)
        XCTAssertEqual(try diffs(source, copy), [])
    }

    func testModificationDateChangeIsReported() throws {
        let source = try makeSource()
        let copy = try makeCopy(of: source)
        let mtime = try FileMetadataFingerprint.read(copy, includeContent: false).modificationDate
        try FileManager.default.setAttributes([.modificationDate: mtime.addingTimeInterval(5)],
                                              ofItemAtPath: copy.path)
        let result = try diffs(source, copy)
        XCTAssertEqual(result.map(\.field), ["modified"])
    }

    func testMissingSourceXattrIsReported() throws {
        let source = try makeSource()
        let copy = try makeCopy(of: source)
        XCTAssertEqual(removexattr(copy.path, tagsXattr, XATTR_NOFOLLOW), 0)
        let result = try diffs(source, copy)
        XCTAssertEqual(result.map(\.field), ["xattr \(tagsXattr)"])
        XCTAssertEqual(result.first?.after, "missing")
    }

    func testChangedXattrValueIsReported() throws {
        let source = try makeSource()
        let copy = try makeCopy(of: source)
        try setXattr(tagsXattr, "other", on: copy)
        XCTAssertEqual(try diffs(source, copy).map(\.field), ["xattr \(tagsXattr)"])
    }

    func testDestinationOnlyXattrIsReportedExceptProvenance() throws {
        let source = try makeSource()
        let copy = try makeCopy(of: source)
        try setXattr("com.apple.provenance", "x", on: copy)
        XCTAssertEqual(try diffs(source, copy), [])
        try setXattr("com.example.x", "y", on: copy)
        let result = try diffs(source, copy)
        XCTAssertEqual(result.map(\.field), ["xattr com.example.x"])
        XCTAssertEqual(result.first?.before, "missing")
    }

    func testDatesWithinResolutionAreEqual() throws {
        let source = try makeSource()
        let base = try FileMetadataFingerprint.read(source, includeContent: true)
        let shifted = FileMetadataFingerprint(
            size: base.size,
            creationDate: base.creationDate,
            modificationDate: Date(timeIntervalSinceReferenceDate:
                (base.modificationDate.timeIntervalSinceReferenceDate / 0.01).rounded(.down) * 0.01 + 0.004),
            flags: base.flags,
            xattrDigests: base.xattrDigests,
            contentDigest: base.contentDigest
        )
        let aligned = FileMetadataFingerprint(
            size: base.size, creationDate: base.creationDate,
            modificationDate: Date(timeIntervalSinceReferenceDate:
                (base.modificationDate.timeIntervalSinceReferenceDate / 0.01).rounded(.down) * 0.01),
            flags: base.flags, xattrDigests: base.xattrDigests, contentDigest: base.contentDigest
        )
        XCTAssertEqual(FileMetadataFingerprint.differences(
            source: aligned, destination: shifted, timeResolution: 0.01), [])
        XCTAssertEqual(FileMetadataFingerprint.differences(
            source: aligned, destination: shifted, timeResolution: 0.000_001).map(\.field), ["modified"])
    }

    func testContentDifferenceIsReported() throws {
        let source = try makeSource("hello world")
        let copy = try makeCopy(of: source)
        let original = try FileMetadataFingerprint.read(copy, includeContent: false)
        try Data("hellO world".utf8).write(to: copy)
        try FileManager.default.setAttributes(
            [.modificationDate: original.modificationDate], ofItemAtPath: copy.path)
        let result = try diffs(source, copy, resolution: 1)
        XCTAssertEqual(result.map(\.field), ["content"])
    }

    func testTimeResolutionByVolume() {
        let resolution = FileMetadataFingerprint.timeResolution(forVolumeOf: root)
        XCTAssertTrue([0.000_001, 0.01, 1].contains(resolution))
    }
}
