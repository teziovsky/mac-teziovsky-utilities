import Foundation
import UserNotifications

enum ExternalDriveStep: Equatable {
    case review
    case moving
    case summary
}

struct ExternalDriveProgress: Equatable {
    var unitIndex = 0
    var unitCount = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    /// The current unit's first path (a Live Photo pair counts as one "file" here).
    var currentPath = ""
    var currentFileBytesDone: Int64 = 0
    var currentFileBytesTotal: Int64 = 0
    var startedAt: Date?
    var estimatedRemaining: TimeInterval?
}

struct ExternalDriveRunResult: Identifiable, Equatable {
    var id: String { relativePath }
    let relativePath: String
    let outcome: ExternalDriveUnitOutcome
}

struct ExternalDriveRunSummary: Equatable {
    enum Kind: Equatable {
        case move
        case trashExisting
    }

    let kind: Kind
    let attemptedUnits: Int
    let succeededUnits: Int
    let results: [ExternalDriveRunResult]
    let wasCancelled: Bool
    let stoppedReason: String?
}

/// Posts a local notification. A no-op outside an app bundle (no bundle identifier, or `swift test`),
/// where `UNUserNotificationCenter` would crash.
enum ExternalDriveNotifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didRequestAuthorization = false

    static func post(title: String, body: String) {
        // `swift test` runs inside xctest, which has a bundle identifier but no app bundle; the
        // notification center throws there too, so require a real `.app`.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        let shouldRequest = lock.withLock {
            defer { didRequestAuthorization = true }
            return !didRequestAuthorization
        }
        if shouldRequest {
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { center.add(request) }
            }
        } else {
            center.add(request)
        }
    }
}

/// Cancel flag and progress throttle shared with the mover's off-main progress callback.
private final class ExternalDriveRunControl: @unchecked Sendable {
    private static let reportInterval: TimeInterval = 0.1
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = Date.distantPast

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    /// True at most ~10 times a second, so huge files don't flood the main actor.
    func shouldReport(now: Date = Date()) -> Bool {
        lock.withLock {
            guard now.timeIntervalSince(lastReport) >= Self.reportInterval else { return false }
            lastReport = now
            return true
        }
    }
}

/// What every unit of one run shares.
private struct ExternalDriveRunContext: Sendable {
    let kind: ExternalDriveRunSummary.Kind
    let source: URL
    let destinationRoot: URL
    let fingerprints: [String: FileMetadataFingerprint]
    let control: ExternalDriveRunControl
    let operationID: UUID
}

/// Drives "Move to External Drive": check (scan, classify, preflight), move the ready units one by one,
/// cancel, summary and one notification per run.
@MainActor
final class ExternalDriveTransferService: ObservableObject {
    static let notificationTitle = "Move to External Drive"

    @Published private(set) var step: ExternalDriveStep = .review
    @Published private(set) var sourceURL: URL?
    @Published private(set) var destination: ExternalDriveFolderResolution = .notChosen
    @Published private(set) var preflightState: ExternalDrivePreflight = .notChosen
    @Published private(set) var review: ExternalDriveReview?
    @Published private(set) var isChecking = false
    @Published private(set) var checkProgress = FileDateRepairProgress()
    /// Why the last check produced no review although both folders were usable (e.g. unreadable source).
    @Published private(set) var checkFailure: String?
    @Published private(set) var isTransferring = false
    @Published private(set) var progress = ExternalDriveProgress()
    @Published private(set) var summary: ExternalDriveRunSummary?

    private let mover: ExternalDriveMover
    private let preflight: (ExternalDriveFolderResolution) -> ExternalDrivePreflight
    private let folders: (ExternalDriveFolderRole) -> ExternalDriveFolderResolution
    private let notify: (String, String) -> Void

    private var sourceOverride: URL?
    private var checkedFingerprints: [String: FileMetadataFingerprint] = [:]
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var runControl: ExternalDriveRunControl?
    private var runKind: ExternalDriveRunSummary.Kind?
    private let sleepAssertion = SleepAssertion()

    init(
        mover: ExternalDriveMover = ExternalDriveMover(log: { ExternalDriveLog.shared.append($0) }),
        preflight: @escaping (ExternalDriveFolderResolution) -> ExternalDrivePreflight = {
            ExternalDriveLocations.preflight(destination: $0)
        },
        folders: @escaping (ExternalDriveFolderRole) -> ExternalDriveFolderResolution =
            AppSettings.resolveExternalDriveFolder,
        notify: @escaping (String, String) -> Void = ExternalDriveNotifier.post
    ) {
        self.mover = mover
        self.preflight = preflight
        self.folders = folders
        self.notify = notify
    }

    var isRunning: Bool { isChecking || isTransferring }

    var activityTitle: String? {
        if isChecking { return "Checking the source folder" }
        guard isTransferring, let runKind else { return nil }
        switch runKind {
        case .move: return "Moving files to \(destinationName)"
        case .trashExisting: return "Moving originals already on \(destinationName) to the Trash"
        }
    }

    var destinationName: String {
        switch destination {
        case let .resolved(url): return url.lastPathComponent
        case let .unavailable(path): return URL(fileURLWithPath: path).lastPathComponent
        case .notChosen: return "the drive"
        }
    }

    // MARK: Check

    /// Resolves both folders, runs the preflight and, when the drive is ready, scans and classifies the source.
    func check() {
        guard !isTransferring else { return }
        cancelCheck()
        step = .review
        review = nil
        summary = nil
        checkFailure = nil
        checkedFingerprints = [:]
        checkProgress = FileDateRepairProgress()

        let source = resolvedSource()
        sourceURL = source
        destination = folders(.destination)
        preflightState = preflight(destination)
        guard let source, case let .resolved(destinationRoot) = destination,
              case .ready = preflightState else { return }

        isChecking = true
        let operationID = UUID()
        self.operationID = operationID
        operationTask = Task { [weak self] in
            await self?.runCheck(source: source, destinationRoot: destinationRoot, operationID: operationID)
        }
    }

    private func resolvedSource() -> URL? {
        if let sourceOverride { return sourceOverride }
        if case let .resolved(url) = folders(.source) { return url }
        return nil
    }

    private func runCheck(source: URL, destinationRoot: URL, operationID: UUID) async {
        let extensions = FileDateRepairExtensions.parse(AppSettings.localMediaExtensions)
        let conversionConfig = AppSettings.localMediaConversionConfig
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let destinationAccess = destinationRoot.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if destinationAccess { destinationRoot.stopAccessingSecurityScopedResource() }
            if self.operationID == operationID {
                isChecking = false
                operationTask = nil
                self.operationID = nil
            }
        }

        do {
            let scan = try await FileDateRepairScanner.scanOutputs(
                directory: source,
                supportedExtensions: extensions,
                conversionConfig: conversionConfig
            ) { progress in
                await MainActor.run {
                    if self.operationID == operationID { self.checkProgress = progress }
                }
            }
            try Task.checkCancellation()
            let checked = await Task.detached(priority: .userInitiated) {
                Self.classify(scan, source: source, destination: destinationRoot, extensions: extensions)
            }.value
            try Task.checkCancellation()
            guard self.operationID == operationID else { return }
            review = checked.review
            checkedFingerprints = checked.fingerprints
        } catch is CancellationError {
            return
        } catch {
            guard self.operationID == operationID else { return }
            checkFailure = error.localizedDescription
        }
    }

    /// Uses `url` as the source for this session (⌘O), then checks it.
    func useSource(_ url: URL) {
        guard !isTransferring else { return }
        sourceOverride = url
        check()
    }

    private nonisolated static func classify(
        _ scan: FileDateScanOutputs, source: URL, destination: URL, extensions: Set<String>
    ) -> (review: ExternalDriveReview, fingerprints: [String: FileMetadataFingerprint]) {
        let review = ExternalDriveClassifier.classify(
            scan,
            otherFiles: ExternalDriveClassifier.otherFiles(in: source, supportedExtensions: extensions),
            byteCount: { path in
                var info = stat()
                guard lstat(source.appendingPathComponent(path).path, &info) == 0 else { return 0 }
                return Int64(info.st_size)
            },
            existsOnDestination: { path in
                // An unreadable destination entry counts as present: never offer it as ready.
                if case .success(false) = ExternalDriveMoverFileSystem.entryExists(
                    destination.appendingPathComponent(path)) { return false }
                return true
            }
        )
        var fingerprints: [String: FileMetadataFingerprint] = [:]
        for path in (review.readyUnits + review.existingUnits).flatMap(\.relativePaths) {
            // A file that can't be read now fails its unit later as "changed since the check".
            fingerprints[path] = try? FileMetadataFingerprint.read(
                source.appendingPathComponent(path), includeContent: false)
        }
        return (review, fingerprints)
    }

    // MARK: Navigation

    /// Stops a running check now, or a run after its current unit (which rolls back if it hasn't verified).
    func cancel() {
        if isTransferring {
            runControl?.cancel()
        } else if isChecking {
            cancelCheck()
        }
    }

    private func cancelCheck() {
        guard isChecking else { return }
        operationTask?.cancel()
        operationTask = nil
        operationID = nil
        isChecking = false
    }

    /// Summary → review (and a fresh check): true. Review → false, so the caller goes home.
    /// Moving → false and nothing happens (commands block it as busy).
    func goBack() -> Bool {
        switch step {
        case .moving, .review:
            return false
        case .summary:
            summary = nil
            step = .review
            check()
            return true
        }
    }

    func reset() {
        runControl?.cancel()
        operationTask?.cancel()
        operationTask = nil
        operationID = nil
        runControl = nil
        runKind = nil
        isChecking = false
        isTransferring = false
        sleepAssertion.release()
        step = .review
        review = nil
        summary = nil
        checkFailure = nil
        checkedFingerprints = [:]
        progress = ExternalDriveProgress()
        checkProgress = FileDateRepairProgress()
    }
}

// MARK: - Runs

extension ExternalDriveTransferService {
    /// Moves every ready unit, provided they fit on the drive.
    func moveReady() {
        guard !isRunning, let review, !review.readyUnits.isEmpty else { return }
        preflightState = preflight(destination)
        guard case let .ready(freeBytes) = preflightState, review.readyByteCount <= freeBytes else { return }
        startRun(.move, units: review.readyUnits)
    }

    /// Trashes the originals whose identical copies are already on the drive.
    func trashExistingOriginals() {
        guard !isRunning, let review, !review.existingUnits.isEmpty else { return }
        preflightState = preflight(destination)
        guard case .ready = preflightState else { return }
        startRun(.trashExisting, units: review.existingUnits)
    }

    private func startRun(_ kind: ExternalDriveRunSummary.Kind, units: [ExternalDriveUnit]) {
        guard let source = sourceURL, case let .resolved(destinationRoot) = destination else { return }
        let control = ExternalDriveRunControl()
        let operationID = UUID()
        self.operationID = operationID
        runControl = control
        runKind = kind
        summary = nil
        isTransferring = true
        progress = ExternalDriveProgress(
            unitCount: units.count, bytesTotal: units.reduce(0) { $0 + $1.byteCount }, startedAt: Date())
        step = .moving
        sleepAssertion.acquire(reason: activityTitle ?? Self.notificationTitle)
        let run = ExternalDriveRunContext(
            kind: kind, source: source, destinationRoot: destinationRoot,
            fingerprints: checkedFingerprints, control: control, operationID: operationID)

        operationTask = Task { [weak self] in
            guard let self else { return }
            let sourceAccess = source.startAccessingSecurityScopedResource()
            let destinationAccess = destinationRoot.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                if destinationAccess { destinationRoot.stopAccessingSecurityScopedResource() }
            }

            var results: [ExternalDriveRunResult] = []
            var stoppedReason: String?
            var completedBytes: Int64 = 0
            for (index, unit) in units.enumerated() {
                guard !control.isCancelled, self.operationID == operationID else { break }
                beginUnit(index, unit, completedBytes: completedBytes)
                let outcome = await perform(unit, index: index, completedBytes: completedBytes, in: run)
                guard self.operationID == operationID else { return }
                results.append(ExternalDriveRunResult(relativePath: unit.id, outcome: outcome))
                completedBytes += unit.byteCount
                finishUnit(completedBytes: completedBytes)
                if let reason = disconnectReason(after: outcome) {
                    stoppedReason = reason
                    break
                }
            }
            guard self.operationID == operationID else { return }
            finishRun(kind, unitCount: units.count, results: results,
                      wasCancelled: (control.isCancelled && results.count < units.count)
                        || results.contains { $0.outcome == .cancelled },
                      stoppedReason: stoppedReason)
        }
    }

    /// Runs one unit off the main actor; progress reaches the main actor throttled, cancel is answered at once.
    private func perform(_ unit: ExternalDriveUnit, index: Int, completedBytes: Int64,
                         in run: ExternalDriveRunContext) async -> ExternalDriveUnitOutcome {
        let mover = mover
        let service = self
        return await Task.detached(priority: .userInitiated) {
            switch run.kind {
            case .move:
                return mover.move(unit, sourceRoot: run.source, destinationRoot: run.destinationRoot,
                                  checkedFingerprints: run.fingerprints) { bytes in
                    if run.control.shouldReport() {
                        Task { @MainActor in
                            service.reportUnitBytes(bytes, base: completedBytes, index: index,
                                                    operationID: run.operationID)
                        }
                    }
                    return !run.control.isCancelled
                }
            case .trashExisting:
                return mover.trashOriginalIfIdentical(unit, sourceRoot: run.source,
                                                      destinationRoot: run.destinationRoot)
            }
        }.value
    }

    /// After a failure, checks the drive is still there; returns the stop reason when it isn't.
    private func disconnectReason(after outcome: ExternalDriveUnitOutcome) -> String? {
        switch outcome {
        case .failed, .destinationUnavailable: break
        default: return nil
        }
        let state = preflight(destination)
        if case .ready = state { return nil }
        preflightState = state
        return "\(destinationName) was disconnected. Connect it and press Check Again (⌘R)."
    }

    private func beginUnit(_ index: Int, _ unit: ExternalDriveUnit, completedBytes: Int64) {
        progress.unitIndex = index
        progress.currentPath = unit.id
        progress.currentFileBytesDone = 0
        progress.currentFileBytesTotal = unit.byteCount
        progress.bytesDone = completedBytes
        progress.estimatedRemaining = estimatedRemaining()
    }

    private func reportUnitBytes(_ bytes: Int64, base: Int64, index: Int, operationID: UUID) {
        // A late, throttled report must not move the bars backwards or into the next unit.
        guard self.operationID == operationID, progress.unitIndex == index else { return }
        progress.currentFileBytesDone = max(progress.currentFileBytesDone, min(bytes, progress.currentFileBytesTotal))
        progress.bytesDone = max(progress.bytesDone, base + min(bytes, progress.currentFileBytesTotal))
        progress.estimatedRemaining = estimatedRemaining()
    }

    private func finishUnit(completedBytes: Int64) {
        progress.currentFileBytesDone = progress.currentFileBytesTotal
        progress.bytesDone = completedBytes
        progress.estimatedRemaining = estimatedRemaining()
    }

    /// From the average speed so far, once the run has gone on for more than 2 s.
    private func estimatedRemaining(now: Date = Date()) -> TimeInterval? {
        guard let startedAt = progress.startedAt, progress.bytesDone > 0 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 2 else { return nil }
        let remaining = max(0, progress.bytesTotal - progress.bytesDone)
        return elapsed * Double(remaining) / Double(progress.bytesDone)
    }

    private func finishRun(_ kind: ExternalDriveRunSummary.Kind, unitCount: Int,
                           results: [ExternalDriveRunResult], wasCancelled: Bool, stoppedReason: String?) {
        let success: ExternalDriveUnitOutcome = kind == .move ? .moved : .trashedOriginal
        let succeeded = results.filter { $0.outcome == success }.count
        summary = ExternalDriveRunSummary(
            kind: kind, attemptedUnits: results.count, succeededUnits: succeeded, results: results,
            wasCancelled: wasCancelled, stoppedReason: stoppedReason)
        isTransferring = false
        operationTask = nil
        operationID = nil
        runControl = nil
        runKind = nil
        progress.estimatedRemaining = nil
        sleepAssertion.release()

        var body = switch kind {
        case .move: "Moved \(succeeded) of \(unitCount) to \(destinationName)"
        case .trashExisting: "Moved \(succeeded) of \(unitCount) originals already on \(destinationName) to the Trash"
        }
        let needAttention = results.count - succeeded
        if needAttention > 0 { body += " — \(needAttention) need attention" }
        if wasCancelled { body += " (cancelled)" }
        notify(Self.notificationTitle, body)
        // Last: observers waiting for the summary see the finished state.
        step = .summary
    }
}
