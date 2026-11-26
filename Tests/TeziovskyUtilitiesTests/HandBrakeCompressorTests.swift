@testable import TeziovskyUtilities
import XCTest

/// Exercises the real `Process` plumbing against small fake HandBrakeCLI scripts.
final class HandBrakeCompressorProcessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandBrakeCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: input)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private var input: URL { root.appendingPathComponent("clip.mov") }
    private var output: URL { root.appendingPathComponent("clip_COMPRESSED.mp4") }

    func testCompletesWhenTheCLIWritesMoreThanAPipeBuffer() async throws {
        let cli = try makeFakeCLI("""
        head -c 300000 /dev/zero | tr '\\0' 'x' 1>&2
        head -c 300000 /dev/zero | tr '\\0' 'y'
        printf 'encoded' > "$out"
        """)

        try await withTimeout(seconds: 10) {
            try await HandBrakeCompressor.compress(
                cliURL: cli,
                inputURL: self.input,
                outputURL: self.output,
                preset: "Fast 1080p30"
            )
        }

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "encoded")
    }

    func testFailedEncodeLeavesNoOutputBehind() async throws {
        let cli = try makeFakeCLI("""
        printf 'truncated' > "$out"
        echo 'Encode failed' 1>&2
        exit 3
        """)

        do {
            try await HandBrakeCompressor.compress(cliURL: cli, inputURL: input, outputURL: output, preset: "P")
            XCTFail("Expected the encode to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Encode failed"), "\(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "A failed encode must not look compressed")
        XCTAssertEqual(try visibleAndHiddenFiles(), ["clip.mov"])
    }

    func testCancellationTerminatesTheRunningEncode() async throws {
        let cli = try makeFakeCLI("""
        printf 'partial' > "$out"
        sleep 30
        printf 'done' > "$out"
        """)

        let started = Date()
        let task = Task {
            try await HandBrakeCompressor.compress(
                cliURL: cli,
                inputURL: self.input,
                outputURL: self.output,
                preset: "P"
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Cancel must stop HandBrakeCLI, not wait for it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try visibleAndHiddenFiles(), ["clip.mov"])
    }

    func testReportsEncodingProgress() async throws {
        let cli = try makeFakeCLI("""
        printf 'Encoding: task 1 of 1, 42.50 %% (30.00 fps, avg 31.00 fps, ETA 00h00m10s)\\r'
        printf 'encoded' > "$out"
        """)
        let recorder = ProgressRecorder()

        try await HandBrakeCompressor.compress(
            cliURL: cli,
            inputURL: input,
            outputURL: output,
            preset: "P",
            onProgress: { recorder.record($0) }
        )

        let last = try XCTUnwrap(recorder.values.last)
        XCTAssertEqual(last.fraction, 0.425, accuracy: 0.0001)
        XCTAssertEqual(last.eta, "00h00m10s")
    }

    // MARK: - Helpers

    /// A fake CLI that exposes the `--output` argument as `$out` to `body`.
    private func makeFakeCLI(_ body: String) throws -> URL {
        let url = root.appendingPathComponent("fake-handbrake-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--output" ]; then out="$2"; fi
          shift
        done
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func visibleAndHiddenFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix("fake-handbrake-") }
            .sorted()
    }

    /// Fails (instead of hanging the suite) when `operation` never returns.
    private func withTimeout(seconds: Double, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        let finished = expectation(description: "operation finished")
        let failure = ErrorBox()
        Task {
            do {
                try await operation()
            } catch {
                failure.error = error
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: seconds)
        if let error = failure.error { throw error }
    }
}

final class HandBrakeProgressParserTests: XCTestCase {
    func testParsesSinglePassProgressAndETA() {
        let progress = HandBrakeProgressParser.lastProgress(
            in: "Encoding: task 1 of 1, 12.34 % (45.67 fps, avg 50.12 fps, ETA 00h01m23s)"
        )

        XCTAssertEqual(progress?.fraction ?? -1, 0.1234, accuracy: 0.0001)
        XCTAssertEqual(progress?.eta, "00h01m23s")
    }

    func testCombinesMultiPassTasksIntoOneFraction() {
        let progress = HandBrakeProgressParser.lastProgress(
            in: "Encoding: task 1 of 2, 100.00 %\rEncoding: task 2 of 2, 50.00 %"
        )

        XCTAssertEqual(progress?.fraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertNil(progress?.eta)
    }

    func testIgnoresTextWithoutProgress() {
        XCTAssertNil(HandBrakeProgressParser.lastProgress(in: "[12:00:00] hb_init: starting libhb thread"))
    }
}

final class DroneExportScannerVideoOnlyTests: XCTestCase {
    func testOnlyVideosAreOfferedForCompression() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroneScanner-\(UUID().uuidString)", isDirectory: true)
        let export = project.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        for name in ["clip.mov", "still.jpg", "cover.png", "voiceover.wav"] {
            try Data().write(to: export.appendingPathComponent(name))
        }

        let exports = try DroneExportScanner.uncompressedExports(projectDirectory: project, config: .default)

        XCTAssertEqual(exports.map(\.relativePath), ["clip.mov"])
    }
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HandBrakeFileProgress] = []

    var values: [HandBrakeFileProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ progress: HandBrakeFileProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}
