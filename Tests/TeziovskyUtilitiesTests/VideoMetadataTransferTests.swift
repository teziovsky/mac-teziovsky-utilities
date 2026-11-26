import AVFoundation
@testable import TeziovskyUtilities
import XCTest

final class VideoMetadataTransferTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoMetadataTransfer-\(UUID().uuidString).mov")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testDateSyncKeepsTheLivePhotoContentIdentifier() async throws {
        try await TestVideoFactory.makeVideo(
            at: url,
            seconds: 2,
            metadata: [
                TestVideoFactory.creationDateItem(Date(timeIntervalSince1970: 1_560_000_000)),
                TestVideoFactory.contentIdentifierItem("6B1D-LIVE-PAIR")
            ]
        )
        let fixtureIdentifier = try await contentIdentifier()
        XCTAssertEqual(fixtureIdentifier, "6B1D-LIVE-PAIR", "Fixture must carry the identifier")

        let target = Date(timeIntervalSince1970: 1_430_000_000)
        try await VideoMetadataTransfer.synchronizeCreationDates(in: url, to: target)

        let identifierAfterSync = try await contentIdentifier()
        XCTAssertEqual(identifierAfterSync, "6B1D-LIVE-PAIR")
        let evidence = try await MediaMetadataReader.readDateEvidence(url: url, isVideo: true)
        let container = try XCTUnwrap(evidence.first { $0.source == .containerCreation }?.date)
        XCTAssertEqual(container.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 1)
    }

    func testDateSyncKeepsDurationAndTracks() async throws {
        try await TestVideoFactory.makeVideo(
            at: url,
            seconds: 3,
            metadata: [TestVideoFactory.creationDateItem(Date(timeIntervalSince1970: 1_560_000_000))]
        )
        let before = try await trackSummary()

        let target = Date(timeIntervalSince1970: 1_430_000_000)
        try await VideoMetadataTransfer.synchronizeCreationDates(in: url, to: target)

        let after = try await trackSummary()
        XCTAssertEqual(after.tracks, before.tracks)
        XCTAssertEqual(after.seconds, before.seconds, accuracy: 0.05)
    }

    func testCreationDateTextKeepsTheOriginalUTCOffset() {
        // 13:20 UTC written for a clip recorded at UTC+9 must read 22:20+09:00, like an iPhone would.
        let text = VideoMetadataTransfer.creationDateString(
            for: Date(timeIntervalSince1970: 1_560_000_000),
            matching: "2010-01-01T10:00:00+0900"
        )

        XCTAssertEqual(text, "2019-06-08T22:20:00+09:00")
    }

    func testCreationDateTextUsesUTCForZuluOriginals() {
        let text = VideoMetadataTransfer.creationDateString(
            for: Date(timeIntervalSince1970: 1_560_000_000),
            matching: "2010-01-01T10:00:00Z"
        )

        XCTAssertEqual(text, "2019-06-08T13:20:00Z")
    }

    private func contentIdentifier() async throws -> String? {
        let items = try await AVURLAsset(url: url).load(.metadata)
        for item in items where (item.key as? String) == "com.apple.quicktime.content.identifier" {
            return try await item.load(.stringValue)
        }
        return nil
    }

    private func trackSummary() async throws -> (tracks: Int, seconds: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        return (tracks.count, duration.seconds)
    }
}
