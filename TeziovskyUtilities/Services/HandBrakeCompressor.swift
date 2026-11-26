import Foundation

struct HandBrakeCompressionProgress: Equatable, Sendable {
    /// 1-based index of the file being encoded.
    var current: Int
    /// Files finished (successfully or not).
    var completed: Int
    var total: Int
    var filename: String
    /// Progress of the current file, 0...1, as reported by HandBrakeCLI.
    var fileFraction: Double
    var eta: String?
    var isComplete: Bool
    var wasCancelled: Bool

    /// Overall fraction across all files.
    var overallFraction: Double {
        guard total > 0 else { return 0 }
        let inFlight = isComplete ? 0 : min(max(fileFraction, 0), 1)
        return min((Double(completed) + inFlight) / Double(total), 1)
    }
}

struct HandBrakeFileProgress: Equatable, Sendable {
    var fraction: Double
    var eta: String?
}

/// Parses HandBrakeCLI's `Encoding: task 1 of 2, 12.34 % (…, ETA 00h01m23s)` status lines.
enum HandBrakeProgressParser {
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"Encoding: task (\d+) of (\d+), ([0-9]+(?:\.[0-9]+)?) %(?:[^\r\n]*?ETA ([0-9]+h[0-9]{2}m[0-9]{2}s))?"#
    )

    static func lastProgress(in text: String) -> HandBrakeFileProgress? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.matches(in: text, range: range).last,
              let task = Double(substring(text, match.range(at: 1)) ?? ""),
              let tasks = Double(substring(text, match.range(at: 2)) ?? ""),
              let percent = Double(substring(text, match.range(at: 3)) ?? ""),
              tasks > 0 else {
            return nil
        }
        let fraction = ((task - 1) + percent / 100) / tasks
        return HandBrakeFileProgress(fraction: min(max(fraction, 0), 1), eta: substring(text, match.range(at: 4)))
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

enum HandBrakeCompressorError: LocalizedError {
    case cliNotFound
    case presetListFailed(String)
    case compressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "HandBrakeCLI was not found. Set its path in Settings → Drone."
        case let .presetListFailed(message):
            return "Could not load HandBrake presets: \(message)"
        case let .compressionFailed(message):
            return message
        }
    }
}

enum HandBrakeCompressor {
    static func listPresets(cliURL: URL) async throws -> [String] {
        let output = try await runCLI(
            executable: cliURL,
            arguments: ["--preset-list"],
            failureLabel: nil
        )
        return parsePresetNames(from: output)
    }

    /// Encodes `inputURL` into a hidden `.partial` sibling and moves it to `outputURL` only after
    /// HandBrakeCLI exits successfully. A failed, cancelled or interrupted encode therefore never
    /// leaves a file that looks like a finished compressed copy.
    static func compress(
        cliURL: URL,
        inputURL: URL,
        outputURL: URL,
        preset: String,
        onProgress: @escaping @Sendable (HandBrakeFileProgress) -> Void = { _ in }
    ) async throws {
        let fileManager = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let partialURL = partialOutputURL(for: outputURL)
        try? fileManager.removeItem(at: partialURL)

        do {
            _ = try await runCLI(
                executable: cliURL,
                arguments: [
                    "--input", inputURL.path,
                    "--output", partialURL.path,
                    "--preset", preset
                ],
                failureLabel: inputURL.lastPathComponent,
                onOutput: { recentText in
                    if let progress = HandBrakeProgressParser.lastProgress(in: recentText) {
                        onProgress(progress)
                    }
                }
            )
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: partialURL.path) else {
                throw HandBrakeCompressorError.compressionFailed(
                    "\(inputURL.lastPathComponent): HandBrakeCLI finished without writing an output file."
                )
            }
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            try fileManager.moveItem(at: partialURL, to: outputURL)
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }
    }

    /// Hidden (so scanners skip it) and with the real extension (HandBrake picks the container from it).
    static func partialOutputURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().lastPathComponent
        let ext = outputURL.pathExtension
        let name = ext.isEmpty ? ".\(base).partial" : ".\(base).partial.\(ext)"
        return outputURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func parsePresetNames(from output: String) -> [String] {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let presetList = json["PresetList"] as? [[String: Any]] {
                let names = presetList.compactMap { $0["PresetName"] as? String }
                if !names.isEmpty { return names.sorted() }
            }
        }

        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("[")
                    && !line.hasPrefix("+")
                    && !line.hasPrefix("<")
                    && line != "Presets:"
            }
            .sorted()
    }

    /// Runs a CLI tool, draining stdout/stderr while it runs (a full pipe would block the tool
    /// forever) and terminating it when the calling task is cancelled.
    static func runCLI(
        executable: URL,
        arguments: [String],
        failureLabel: String?,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = ProcessOutputCollector(onRecentText: onOutput)
        let drained = DispatchGroup()
        for pipe in [stdout, stderr] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    collector.append(chunk)
                }
            }
        }
        let cancellation = CancellationFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { process in
                    // Grandchildren may keep the pipes open; don't wait for them forever.
                    _ = drained.wait(timeout: .now() + 2)
                    let output = collector.text
                    if cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        let label = failureLabel.map { "\($0): " } ?? ""
                        let tail = String(output.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: HandBrakeCompressorError.compressionFailed(label + tail))
                    }
                }
                do {
                    try process.run()
                } catch {
                    for pipe in [stdout, stderr] {
                        pipe.fileHandleForReading.readabilityHandler = nil
                    }
                    continuation.resume(throwing: error)
                    return
                }
                if cancellation.isCancelled {
                    process.terminate()
                }
            }
        } onCancel: {
            cancellation.cancel()
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// Thread-safe sink for process output; keeps a bounded transcript plus a short tail for
/// progress parsing (a status line can be split across two reads).
private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var transcript = Data()
    private var recent = ""
    private let transcriptLimit = 1 << 20
    private let onRecentText: (@Sendable (String) -> Void)?

    init(onRecentText: (@Sendable (String) -> Void)?) {
        self.onRecentText = onRecentText
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.decode(transcript)
    }

    /// UTF-8 when valid; Latin-1 (never fails) for chunks split inside a multi-byte character.
    private static func decode(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    func append(_ chunk: Data) {
        lock.lock()
        transcript.append(chunk)
        if transcript.count > transcriptLimit {
            transcript.removeFirst(transcript.count - transcriptLimit)
        }
        recent = String((recent + Self.decode(chunk)).suffix(512))
        let snapshot = recent
        lock.unlock()
        onRecentText?(snapshot)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
final class HandBrakeCompressionSession: ObservableObject {
    @Published private(set) var progress: HandBrakeCompressionProgress?
    @Published private(set) var failures: [OrganizeFailure] = []
    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?
    private let sleepAssertion = SleepAssertion()

    func cancel() {
        task?.cancel()
    }

    func compressAll(
        projectDirectory: URL,
        exports: [DroneUncompressedExport],
        config: DroneFinalizeConfig,
        preset: String
    ) {
        cancel()
        failures = []
        isRunning = true
        progress = HandBrakeCompressionProgress(
            current: 0,
            completed: 0,
            total: exports.count,
            filename: "",
            fileFraction: 0,
            eta: nil,
            isComplete: false,
            wasCancelled: false
        )

        // Even a single 4K export can take most of an hour; never let the Mac idle-sleep mid-encode.
        sleepAssertion.acquire(reason: "Compressing \(exports.count) drone export\(exports.count == 1 ? "" : "s")")

        let runID = UUID()
        self.runID = runID
        task = Task {
            defer {
                if self.runID == runID {
                    sleepAssertion.release()
                    isRunning = false
                }
            }

            guard let cliURL = DroneToolPaths.resolveHandBrakeCLI(configuredPath: config.handBrakeCLIPath) else {
                failures = [OrganizeFailure(filename: "", message: HandBrakeCompressorError.cliNotFound.localizedDescription)]
                progress?.isComplete = true
                return
            }

            let exportDir = projectDirectory.appendingPathComponent(config.exportDirectoryName, isDirectory: true)
            var issues: [OrganizeFailure] = []

            for (index, export) in exports.enumerated() {
                guard !Task.isCancelled else {
                    finish(issues: issues, cancelled: true)
                    return
                }

                progress?.current = index + 1
                progress?.filename = export.relativePath
                progress?.fileFraction = 0
                progress?.eta = nil

                let inputURL = exportDir.appendingPathComponent(export.relativePath)
                let outputRelative = DroneExportScanner.compressedRelativePath(for: export.relativePath, config: config)
                let outputURL = exportDir.appendingPathComponent(outputRelative)

                do {
                    try await HandBrakeCompressor.compress(
                        cliURL: cliURL,
                        inputURL: inputURL,
                        outputURL: outputURL,
                        preset: preset,
                        onProgress: progressHandler(runID: runID, fileIndex: index + 1)
                    )
                } catch is CancellationError {
                    finish(issues: issues, cancelled: true)
                    return
                } catch {
                    issues.append(OrganizeFailure(filename: export.relativePath, message: error.localizedDescription))
                }
                progress?.completed = index + 1
            }

            finish(issues: issues, cancelled: false)
        }
    }

    private var runID: UUID?

    /// HandBrake reports progress off the main actor; stale updates from a finished file or an
    /// earlier run are dropped.
    private func progressHandler(runID: UUID, fileIndex: Int) -> @Sendable (HandBrakeFileProgress) -> Void {
        { [weak self] fileProgress in
            Task { @MainActor in
                guard let self, self.runID == runID, self.progress?.current == fileIndex else { return }
                self.progress?.fileFraction = fileProgress.fraction
                self.progress?.eta = fileProgress.eta
            }
        }
    }

    private func finish(issues: [OrganizeFailure], cancelled: Bool) {
        failures = issues
        progress?.wasCancelled = cancelled
        progress?.isComplete = true
        progress?.eta = nil
    }
}

@MainActor
final class HandBrakePresetLoader: ObservableObject {
    @Published private(set) var presets: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load(config: DroneFinalizeConfig) {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            guard let cliURL = DroneToolPaths.resolveHandBrakeCLI(configuredPath: config.handBrakeCLIPath) else {
                errorMessage = HandBrakeCompressorError.cliNotFound.localizedDescription
                presets = []
                return
            }
            do {
                presets = try await HandBrakeCompressor.listPresets(cliURL: cliURL)
            } catch {
                errorMessage = error.localizedDescription
                presets = []
            }
        }
    }
}
