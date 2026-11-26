import AVFoundation
@testable import TeziovskyUtilities
import XCTest

/// A converted video must not gain a container creation date its source never had: an old
/// undated `.3gp` would otherwise jump to the year it was converted.
final class ConvertedVideoDateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertedVideoDate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testLegacyReencodeAddsNoCreationDate() async throws {
        let source = try await makeUndatedVideo("old.mov")
        try await assertConversionAddsNoCreationDate(source: source, kind: .legacyVideo(.mp4, .h264))
    }

    func testPassthroughRemuxAddsNoCreationDate() async throws {
        let source = try await makeUndatedVideo("old.mov")
        try await assertConversionAddsNoCreationDate(source: source, kind: .remuxVideo(.mp4))
    }

    func testHEV1RewrapAddsNoCreationDate() async throws {
        let source = root.appendingPathComponent("old.mp4")
        try await TestVideoFactory.makeHEV1Video(at: source, seconds: 1, fileType: .mp4)
        try setMovieHeaderCreationTime(of: source, secondsSince1904: 0)
        try await assertConversionAddsNoCreationDate(source: source, kind: .remuxVideo(.mov))
    }

    /// Android keeps the capture time only in the movie header; the rewrap carries it over.
    func testHEV1RewrapCarriesTheMovieHeaderDate() async throws {
        let source = root.appendingPathComponent("android.mp4")
        try await TestVideoFactory.makeHEV1Video(at: source, seconds: 1, fileType: .mp4)
        try setMovieHeaderCreationTime(of: source, secondsSince1904: Self.headerSeconds)
        let headerDate = try await movieHeaderDate(of: source)
        XCTAssertEqual(headerDate?.timeIntervalSince1970 ?? 0, Self.headerDate.timeIntervalSince1970, accuracy: 1)

        let output = try await convert(source, kind: .remuxVideo(.mov), keepOriginal: true)
        let dates = try await containerCreationDates(of: output)
        XCTAssertEqual(dates.count, 1)
        XCTAssertEqual(dates.first?.timeIntervalSince1970 ?? 0, Self.headerDate.timeIntervalSince1970, accuracy: 1)
    }

    /// The export-session paths copy only the metadata items, never the movie header date.
    func testExportSessionsDoNotPromoteTheMovieHeaderDate() async throws {
        let source = root.appendingPathComponent("header-only.mov")
        try await TestVideoFactory.makeVideo(at: source, seconds: 1)
        try setMovieHeaderCreationTime(of: source, secondsSince1904: Self.headerSeconds)

        for kind: LocalMediaConversionKind in [.legacyVideo(.mp4, .h264), .remuxVideo(.mp4)] {
            let output = try await convert(source, kind: kind, keepOriginal: true)
            let dates = try await containerCreationDates(of: output)
            XCTAssertEqual(dates, [], "\(kind)")
        }
    }

    func testConversionKeepsAnExistingCreationDate() async throws {
        let captured = Date(timeIntervalSince1970: 1_200_000_000)
        let source = root.appendingPathComponent("dated.mov")
        try await TestVideoFactory.makeVideo(
            at: source,
            seconds: 1,
            metadata: [TestVideoFactory.creationDateItem(captured)]
        )

        for kind: LocalMediaConversionKind in [.legacyVideo(.mp4, .h264), .remuxVideo(.mp4)] {
            let output = try await convert(source, kind: kind, keepOriginal: true)
            let dates = try await containerCreationDates(of: output)
            XCTAssertEqual(dates.count, 1, "\(kind)")
            if let date = dates.first {
                XCTAssertEqual(date.timeIntervalSince1970, captured.timeIntervalSince1970, accuracy: 1, "\(kind)")
            }
            try FileManager.default.removeItem(at: output)
        }
    }

    // MARK: - Helpers

    private func assertConversionAddsNoCreationDate(
        source: URL,
        kind: LocalMediaConversionKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let before = try await containerCreationDates(of: source)
        XCTAssertEqual(before, [], "the source must have no creation-date item", file: file, line: line)
        let header = try await movieHeaderDate(of: source)
        XCTAssertNil(header, "the source must have no movie header date", file: file, line: line)

        let output = try await convert(source, kind: kind, keepOriginal: false)
        let after = try await containerCreationDates(of: output)
        XCTAssertEqual(after, [], "\(kind) must not invent a creation date", file: file, line: line)
    }

    private func convert(_ source: URL, kind: LocalMediaConversionKind, keepOriginal: Bool) async throws -> URL {
        let fileExtension: String
        switch kind {
        case .legacyVideo(let container, _), .remuxVideo(let container):
            fileExtension = container == .mp4 ? "mp4" : "mov"
        case .heicToJPEG:
            fileExtension = "jpg"
        }
        let destination = root.appendingPathComponent("converted-\(UUID().uuidString).\(fileExtension)")
        try await LocalMediaConverter.convert(LocalMediaConversionItem(
            sourceURL: source,
            sourceRelativePath: source.lastPathComponent,
            destinationURL: destination,
            destinationRelativePath: destination.lastPathComponent,
            kind: kind,
            keepOriginal: keepOriginal,
            destinationWasRenamed: false
        ))
        return destination
    }

    /// 3 345 000 000 s after 1 Jan 1904 is 30 Dec 2009 06:40 UTC.
    private static let headerSeconds: UInt32 = 3_345_000_000
    private static let headerDate = Date(timeIntervalSince1970: TimeInterval(headerSeconds) - 2_082_844_800)

    /// `AVAssetWriter` stamps the movie header with the time it wrote the file; zero it so the
    /// source is truly undated.
    private func makeUndatedVideo(_ name: String) async throws -> URL {
        let source = root.appendingPathComponent(name)
        try await TestVideoFactory.makeVideo(at: source, seconds: 1)
        try setMovieHeaderCreationTime(of: source, secondsSince1904: 0)
        return source
    }

    private func movieHeaderDate(of url: URL) async throws -> Date? {
        try await AVURLAsset(url: url).load(.creationDate)?.load(.dateValue)
    }

    /// Overwrites the `mvhd` creation time (seconds since 1904) in place.
    private func setMovieHeaderCreationTime(of url: URL, secondsSince1904: UInt32) throws {
        var data = try Data(contentsOf: url)
        let marker = Data("mvhd".utf8)
        let range = try XCTUnwrap(data.range(of: marker), "no mvhd atom")
        let version = data[range.upperBound]
        XCTAssertEqual(version, 0, "only version-0 movie headers are patched")
        let offset = range.upperBound + 4
        let bytes = withUnsafeBytes(of: secondsSince1904.bigEndian) { Data($0) }
        data.replaceSubrange(offset..<(offset + 4), with: bytes)
        try data.write(to: url)
    }

    private func containerCreationDates(of url: URL) async throws -> [Date] {
        try await MediaMetadataReader.readDateEvidence(url: url, isVideo: true)
            .filter { $0.source == .containerCreation }
            .map(\.date)
    }
}
