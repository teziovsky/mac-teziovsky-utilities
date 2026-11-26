import AVFoundation
@testable import TeziovskyUtilities
import XCTest

/// A rewrapped video must actually decode, not only look playable.
final class LocalMediaRemuxVerifierTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemuxVerifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDecodeCheckRejectsHEV1AndAcceptsH264() async throws {
        let hev1 = root.appendingPathComponent("hev1.mp4")
        try await TestVideoFactory.makeHEV1Video(at: hev1, seconds: 1, fileType: .mp4)
        let h264 = root.appendingPathComponent("h264.mov")
        try await TestVideoFactory.makeVideo(at: h264, seconds: 1)

        let hev1Decodes = await LocalMediaRemuxVerifier.decodesAFrame(AVURLAsset(url: hev1))
        let h264Decodes = await LocalMediaRemuxVerifier.decodesAFrame(AVURLAsset(url: h264))
        XCTAssertFalse(hev1Decodes)
        XCTAssertTrue(h264Decodes)
    }

    func testVerificationFailsWhenTheOutputDoesNotDecode() async throws {
        let video = root.appendingPathComponent("clip.mov")
        try await TestVideoFactory.makeVideo(at: video, seconds: 1)

        do {
            try await LocalMediaRemuxVerifier.verify(video, source: video, decodes: { _ in false })
            XCTFail("An output that doesn't decode must fail verification")
        } catch LocalMediaConversionError.verificationFailed {
        }
        try await LocalMediaRemuxVerifier.verify(video, source: video, decodes: { _ in true })
        try await LocalMediaRemuxVerifier.verify(video, source: video)
    }
}
