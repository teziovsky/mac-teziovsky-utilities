import Foundation
import XCTest
@testable import TeziovskyUtilities

final class LocalMediaReplacementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMediaReplacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func scan(_ extensions: Set<String>) async throws -> FileDateScanResult {
        try await FileDateRepairScanner.scan(
            directory: root,
            supportedExtensions: extensions,
            progress: { _ in }
        )
    }

    private func write(_ name: String, marker: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        if let marker {
            LocalMediaConverter.markConverted(url, destination: root.appendingPathComponent(marker))
        }
        return url
    }

    func testMarkedOriginalWithTwinIsAPair() async throws {
        let original = try write("Mia_32.mp4", marker: "Mia_32-converted.mp4")
        let copy = try write("Mia_32-converted.mp4")

        let pairs = try await scan(["mp4"]).replaceablePairs

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.finalName, "Mia_32.mp4")
        XCTAssertEqual(pairs.first?.originalRelativePath, "Mia_32.mp4")
        XCTAssertEqual(pairs.first?.copyRelativePath, "Mia_32-converted.mp4")
        XCTAssertEqual(pairs.first?.originalURL.lastPathComponent, original.lastPathComponent)
        XCTAssertEqual(pairs.first?.copyURL.lastPathComponent, copy.lastPathComponent)
        XCTAssertEqual(pairs.first?.isVideo, true)
    }

    func testHEICPairKeepsJPGName() async throws {
        _ = try write("IMG.heic", marker: "IMG.jpg")
        _ = try write("IMG.jpg")

        let pairs = try await scan(["heic", "jpg"]).replaceablePairs

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.finalName, "IMG.jpg")
        XCTAssertEqual(pairs.first?.isVideo, false)
    }

    func testMarkerWithoutTwinIsNotAPair() async throws {
        _ = try write("Mia_32.mp4", marker: "Mia_32-converted.mp4")

        let pairs = try await scan(["mp4"]).replaceablePairs

        XCTAssertTrue(pairs.isEmpty)
    }

    func testUnmarkedFilesAreNotPairs() async throws {
        _ = try write("Mia_32.mp4")
        _ = try write("Mia_32-converted.mp4")

        let pairs = try await scan(["mp4"]).replaceablePairs

        XCTAssertTrue(pairs.isEmpty)
    }

    func testMarkerPointingAtItselfIsNotAPair() async throws {
        _ = try write("Mia_32.mp4", marker: "Mia_32.mp4")

        let pairs = try await scan(["mp4"]).replaceablePairs

        XCTAssertTrue(pairs.isEmpty)
    }
}
