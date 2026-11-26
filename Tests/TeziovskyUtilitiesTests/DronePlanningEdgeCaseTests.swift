@testable import TeziovskyUtilities
import XCTest

final class DroneSourceMatchingTests: XCTestCase {
    private let mediaExtensions: Set<String> = ["mov", "mp4", "jpg"]
    private let videoExtensions: Set<String> = ["mov", "mp4"]

    func testSidecarFilesAreNeverChosenAsTheOriginal() {
        let plan = makePlan(["clip.LRF", "clip.mov", "clip_COMPRESSED.mp4"])

        XCTAssertEqual(plan.matchedPairs.map(\.sourceRelativePath), ["clip.mov"])
        XCTAssertEqual(plan.leftoverFiles, ["clip.LRF"])
    }

    func testAVideoOriginalIsPreferredForACompressedVideo() {
        let plan = makePlan(["clip.jpg", "clip.mov", "clip_COMPRESSED.mp4"])

        XCTAssertEqual(plan.matchedPairs.map(\.sourceRelativePath), ["clip.mov"])
        XCTAssertEqual(plan.passthroughMedia, ["clip.jpg"])
    }

    private func makePlan(_ files: [String]) -> DroneFinalizePlan {
        DroneFinalizePlanBuilder.makePlan(
            exportFiles: files,
            config: .default,
            isMedia: { self.mediaExtensions.contains(($0 as NSString).pathExtension.lowercased()) },
            isVideo: { self.videoExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        )
    }
}

final class DroneScannerTwinTests: XCTestCase {
    func testACompressedCopyWithAnotherExtensionCountsAsDone() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroneScannerTwin-\(UUID().uuidString)", isDirectory: true)
        let export = project.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try Data().write(to: export.appendingPathComponent("scene.mov"))
        try Data().write(to: export.appendingPathComponent("scene_COMPRESSED.mkv"))

        let pending = try DroneExportScanner.uncompressedExports(projectDirectory: project, config: .default)

        XCTAssertTrue(pending.isEmpty, "scene.mov already has a compressed copy: \(pending.map(\.relativePath))")
    }
}

final class HandBrakePresetListParsingTests: XCTestCase {
    func testParsesTheIndentedPresetListOfHandBrakeCLI1x() {
        let output = """
        HandBrake 1.8.2 (2024081600) - Darwin arm64 - https://handbrake.fr
        General/
            Very Fast 2160p60 4K AV1
                Small H.265 video (up to 2160p60) and AAC stereo audio, in an MP4
                container.
            Fast 1080p30
                H.264 video (up to 1080p30) and AAC stereo audio, in an MP4 container.
        Web/
            Creator 1080p60
                H.264 video (up to 1080p60) and AAC stereo audio, in an MP4 container.
        """

        XCTAssertEqual(
            HandBrakeCompressor.parsePresetNames(from: output),
            ["Creator 1080p60", "Fast 1080p30", "Very Fast 2160p60 4K AV1"]
        )
    }

    func testListingImportsTheUsersHandBrakeAppPresets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandBrakePresets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("fake-handbrake.sh")
        try """
        #!/bin/sh
        case " $* " in
          *" --preset-import-gui "*) printf 'Custom/\\n    My Drone 4K\\n' 1>&2 ;;
          *) printf 'General/\\n    Fast 1080p30\\n' 1>&2 ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let presets = try await HandBrakeCompressor.listPresets(cliURL: cli)

        XCTAssertEqual(presets, ["My Drone 4K"])
    }
}
