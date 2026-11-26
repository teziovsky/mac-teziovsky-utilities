import Foundation

extension LocalPhotosService {
    /// The replaceable pairs the user left ticked.
    var includedReplaceablePairs: [LocalMediaReplaceablePair] {
        replaceablePairs.filter { !isExcluded(path: $0.originalRelativePath, in: .replacement) }
    }

    /// Replaces every ticked original with its converted copy, one pair at a time, then
    /// rescans the folder as after a conversion. The step stays on Convert.
    func replaceOriginals() {
        let plannedPairs = includedReplaceablePairs
        guard !isRunning, !plannedPairs.isEmpty, let directory else { return }
        isReplacing = true
        clearCancellationMessage()
        replacementSummary = LocalMediaReplacementSummary(total: plannedPairs.count)
        replacementProgress = FileDateRepairProgress(total: plannedPairs.count)
        let replacer = makeReplacer()

        startOperation(finish: { [weak self] in self?.isReplacing = false }, work: { [weak self] operationID in
            guard let self else { return }
            let didAccess = directory.startAccessingSecurityScopedResource()
            defer {
                if didAccess { directory.stopAccessingSecurityScopedResource() }
            }

            let run = await replace(plannedPairs, with: replacer, operationID: operationID)
            guard isCurrentOperation(operationID) else { return }
            replacementSummary = run.summary
            // Without a full rescan, at least the pairs already in the Trash leave the list.
            if run.wasCancelled {
                removeReplaceablePairs(run.handledPaths)
            } else if await !rescanAfterReplacement(in: directory, operationID: operationID),
                      isCurrentOperation(operationID) {
                removeReplaceablePairs(run.handledPaths)
            }
            // A cancel that arrived after the last pair (e.g. during the rescan) cancelled nothing.
            if isCurrentOperation(operationID), run.summary.cancelled == 0 {
                clearCancellationMessage()
            }
        })
    }

    private struct ReplacementRun {
        var summary: LocalMediaReplacementSummary
        /// Originals that are now in the Trash.
        var handledPaths: Set<String> = []
        var wasCancelled = false
    }

    private func replace(
        _ pairs: [LocalMediaReplaceablePair],
        with replacer: LocalMediaReplacer,
        operationID: UUID
    ) async -> ReplacementRun {
        var run = ReplacementRun(summary: LocalMediaReplacementSummary(total: pairs.count))
        for (index, pair) in pairs.enumerated() {
            guard !Task.isCancelled, isCurrentOperation(operationID) else {
                run.summary.cancelled += pairs.count - index
                run.wasCancelled = true
                return run
            }
            replacementProgress = FileDateRepairProgress(
                processed: index,
                total: pairs.count,
                currentPath: pair.originalRelativePath
            )
            switch await replacer.replace(pair) {
            case .replaced:
                run.summary.replaced += 1
                run.handledPaths.insert(pair.originalRelativePath)
            case .replacedKeptCopyName(let message):
                run.summary.keptCopyName += 1
                run.summary.issues.append(issue(pair, message))
                run.handledPaths.insert(pair.originalRelativePath)
            case .failed(let message):
                run.summary.failed += 1
                run.summary.issues.append(issue(pair, message))
            case .cancelled:
                run.summary.cancelled += 1
            }
            guard isCurrentOperation(operationID) else { return run }
            replacementProgress.processed = index + 1
            replacementSummary = run.summary
        }
        if Task.isCancelled {
            run.wasCancelled = true
        }
        return run
    }

    private func issue(_ pair: LocalMediaReplaceablePair, _ message: String) -> FileDateRepairFailure {
        FileDateRepairFailure(relativePath: pair.originalRelativePath, message: message)
    }

    /// Rescans so replaced pairs disappear and renamed copies show under their new names.
    /// Returns false when the rescan did not complete.
    private func rescanAfterReplacement(in directory: URL, operationID: UUID) async -> Bool {
        replacementProgress.currentPath = "Refreshing previews…"
        do {
            let refreshed = try await FileDateRepairScanner.scan(
                directory: directory,
                supportedExtensions: FileDateRepairExtensions.parse(AppSettings.localMediaExtensions),
                conversionConfig: AppSettings.localMediaConversionConfig,
                progress: { _ in }
            )
            guard isCurrentOperation(operationID) else { return false }
            applyRefreshedScan(refreshed)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentOperation(operationID) else { return false }
            appendFailure(FileDateRepairFailure(
                relativePath: directory.lastPathComponent,
                message: "Originals were replaced, but previews could not refresh: \(error.localizedDescription)"
            ))
            return false
        }
    }
}
