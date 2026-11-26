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

    /// Exact nanosecond birth time; going through `Date` would lose precision.
    private func setBirthTime(_ nanoseconds: Int64, on url: URL) throws {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var spec = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
        let result = setattrlist(url.path, &list, &spec, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        XCTAssertEqual(result, 0, "setattrlist failed: errno \(errno)")
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
        try setBirthTime(sourceFingerprint.creationNanoseconds, on: copy)
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

    private func fingerprint(
        size: UInt64 = 10, created: Int64 = 1_700_000_000_000_000_000,
        modified: Int64 = 1_700_000_000_000_000_000, flags: UInt32 = 0,
        content: Data? = Data([1])
    ) -> FileMetadataFingerprint {
        FileMetadataFingerprint(size: size, creationNanoseconds: created, modificationNanoseconds: modified,
                                flags: flags, xattrDigests: [:], contentDigest: content)
    }

    private func fields(_ source: FileMetadataFingerprint, _ destination: FileMetadataFingerprint,
                        resolution: TimeInterval = 0.000_001) -> [String] {
        FileMetadataFingerprint.differences(source: source, destination: destination, timeResolution: resolution)
            .map(\.field)
    }

    func testDatesWithinResolutionAreEqual() {
        let base: Int64 = 1_700_000_000_000_000_000
        let source = fingerprint(created: base, modified: base)
        let near = fingerprint(created: base + 4_000_000, modified: base + 4_000_000)
        XCTAssertEqual(fields(source, near, resolution: 0.01), [])
        XCTAssertEqual(fields(source, near, resolution: 0.000_001), ["created", "modified"])
    }

    func testDatesStraddlingABucketAreDifferent() {
        let base: Int64 = 1_700_000_000_000_000_000
        let source = fingerprint(modified: base + 9_000_000)
        let next = fingerprint(modified: base + 11_000_000)
        XCTAssertEqual(fields(source, next, resolution: 0.01), ["modified"])
    }

    func testMicrosecondTruncatedDestinationIsEqualAtMicrosecondResolution() {
        let source = fingerprint(modified: 1_700_000_000_123_456_789)
        let truncated = fingerprint(modified: 1_700_000_000_123_456_000)
        XCTAssertEqual(fields(source, truncated), [])
    }

    func testSizeAndCreatedDifferencesAreReported() {
        XCTAssertEqual(fields(fingerprint(size: 1), fingerprint(size: 2)), ["size"])
        XCTAssertEqual(fields(fingerprint(created: 1_000_000_000), fingerprint(created: 5_000_000_000)),
                       ["created"])
    }

    func testFlagsDifferenceIsReportedButCompressedIsIgnored() {
        let compressed = UInt32(UF_COMPRESSED)
        XCTAssertEqual(fields(fingerprint(flags: 0), fingerprint(flags: compressed)), [])
        XCTAssertEqual(fields(fingerprint(flags: 0), fingerprint(flags: UInt32(UF_HIDDEN))), ["flags"])
        XCTAssertEqual(fields(fingerprint(flags: compressed), fingerprint(flags: compressed | UInt32(UF_HIDDEN))),
                       ["flags"])
    }

    func testContentDigestOnOneSideOnlyIsReported() {
        XCTAssertEqual(fields(fingerprint(content: Data([1])), fingerprint(content: nil)), ["content"])
        XCTAssertEqual(fields(fingerprint(content: nil), fingerprint(content: Data([1]))), ["content"])
        XCTAssertEqual(fields(fingerprint(content: nil), fingerprint(content: nil)), [])
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

    func testReadRejectsSymlinks() throws {
        let source = try makeSource()
        let link = root.appendingPathComponent("link.dat")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try FileMetadataFingerprint.read(link, includeContent: true))
    }

    func testTimeResolutionByFileSystemType() {
        XCTAssertEqual(FileMetadataFingerprint.timeResolution(forFileSystemType: "exfat"), 0.01)
        XCTAssertEqual(FileMetadataFingerprint.timeResolution(forFileSystemType: "apfs"), 0.000_001)
        XCTAssertEqual(FileMetadataFingerprint.timeResolution(forFileSystemType: "hfs"), 1)
        XCTAssertEqual(FileMetadataFingerprint.timeResolution(forFileSystemType: "msdos"), 1)
        XCTAssertEqual(FileMetadataFingerprint.timeResolution(forFileSystemType: "weird"), 1)
    }

    func testTimeResolutionForTemporaryDirectoryIsAPFS() {
        XCTAssertEqual(FileMetadataFingerprint.timeResolution(forVolumeOf: root), 0.000_001)
        XCTAssertNil(FileMetadataFingerprint.timeResolution(
            forVolumeOf: root.appendingPathComponent("does-not-exist")))
    }
}
