import Foundation
import Photos

@MainActor
final class OrganizeExporter: ObservableObject {
    /// Albums at or above this size keep the Mac awake for the full export.
    static let largeAlbumSleepThreshold = 50

    @Published private(set) var progress: OrganizeProgress?
    @Published private(set) var failures: [OrganizeFailure] = []
    @Published private(set) var isRunning = false
    @Published private(set) var destinationAlbumTitle: String?
    /// Kept after the run: the source album often disappears from the list once emptied.
    @Published private(set) var sourceAlbumName: String?
    @Published private(set) var exportDirectory: URL?
    @Published private(set) var startedAt: Date?

    private var exportTask: Task<Void, Never>?
    private var onFinished: (@MainActor () async -> Void)?
    /// Identifies the current run. A cancelled run keeps finishing its in-flight item in the
    /// background and must not overwrite the state of a run started after it.
    private var runID: UUID?

    func organize(
        items: [MediaItem],
        assetsByID: [String: PHAsset],
        sourceAlbum: PhotoAlbum,
        to exportDirectory: URL,
        photosService: PhotosService,
        onFinished: (@MainActor () async -> Void)? = nil
    ) {
        cancel()
        failures = []
        sourceAlbumName = sourceAlbum.name
        self.exportDirectory = exportDirectory
        startedAt = Date()
        progress = OrganizeProgress(
            current: 0,
            total: items.count,
            filename: "",
            failedCount: 0,
            skippedCount: 0,
            movedCount: 0,
            isComplete: false,
            wasCancelled: false
        )
        guard let targetTitle = PhotosService.destinationAlbumTitle(forSourceAlbumNamed: sourceAlbum.name) else {
            destinationAlbumTitle = nil
            failures = [OrganizeFailure(
                filename: "",
                message: "Set an album suffix in Settings → Photos first; it names the album organized items move to."
            )]
            progress = progress.map { finished($0, cancelled: false) }
            return
        }

        isRunning = true
        self.onFinished = onFinished
        destinationAlbumTitle = targetTitle
        let runID = UUID()
        self.runID = runID
        let sleepAssertion = SleepAssertion()
        if items.count >= Self.largeAlbumSleepThreshold {
            sleepAssertion.acquire(reason: "Exporting \(items.count) items from “\(sourceAlbum.name)”")
        }

        photosService.beginDeferringAlbumReloadFromLibraryChanges()
        let request = OrganizeRequest(
            sourceAlbum: sourceAlbum,
            targetAlbumTitle: targetTitle,
            exportDirectory: exportDirectory,
            photosService: photosService
        )
        exportTask = Task {
            await runOrganize(items: items, assetsByID: assetsByID, request: request, runID: runID)
            sleepAssertion.release()
        }
    }

    func cancel() {
        exportTask?.cancel()
        exportTask = nil
        if isRunning, let current = progress {
            progress = finished(current, cancelled: true)
        }
        isRunning = false
        runID = nil
    }

    private func finished(_ progress: OrganizeProgress, cancelled: Bool) -> OrganizeProgress {
        OrganizeProgress(
            current: progress.current,
            total: progress.total,
            filename: "",
            failedCount: progress.failedCount,
            skippedCount: progress.skippedCount,
            movedCount: progress.movedCount,
            isComplete: true,
            wasCancelled: cancelled
        )
    }

    private func runOrganize(
        items: [MediaItem],
        assetsByID: [String: PHAsset],
        request: OrganizeRequest,
        runID: UUID
    ) async {
        let directoryAccess = ExportDirectoryAccess()
        defer { directoryAccess.endAccess() }
        guard let scopedDirectory = directoryAccess.beginAccess() else {
            if self.runID == runID {
                finishWithAccessError(items: items)
            }
            await request.photosService.endDeferringAlbumReloadFromLibraryChanges()
            return
        }
        try? FileManager.default.createDirectory(at: scopedDirectory, withIntermediateDirectories: true)

        // Captured once so a Settings change mid-run cannot mix export styles in one album.
        let options = ExportOptions(
            preferEdited: AppSettings.photosExportEditedVersions,
            includeCompanions: AppSettings.photosExportCompanionFiles,
            organizeByYear: AppSettings.organizeByYearEnabled
        )
        var tally = OrganizeTally()

        for item in items {
            if Task.isCancelled { break }
            if self.runID == runID {
                progress = tally.progress(total: items.count, filename: item.filename, isComplete: false)
            }
            let outcome = await organize(
                item,
                asset: assetsByID[item.id],
                request: request,
                scopedDirectory: scopedDirectory,
                options: options
            )
            tally.record(outcome, for: item)
        }

        let cancelled = Task.isCancelled
        // After cancel() this run no longer owns the UI unless no newer run has started.
        let ownsState = self.runID == runID || self.runID == nil
        if ownsState {
            failures = tally.failures
            progress = tally.progress(total: items.count, filename: "", isComplete: true, wasCancelled: cancelled)
        }
        if self.runID == runID {
            isRunning = false
            exportTask = nil
            self.runID = nil
        }
        let finishedHandler = ownsState ? onFinished : nil
        if ownsState { onFinished = nil }

        await request.photosService.endDeferringAlbumReloadFromLibraryChanges()
        if !cancelled {
            await finishedHandler?()
        }
    }

    private func organize(
        _ item: MediaItem,
        asset: PHAsset?,
        request: OrganizeRequest,
        scopedDirectory: URL,
        options: ExportOptions
    ) async -> OrganizeItemOutcome {
        guard let asset else {
            return .failed("Asset not found")
        }
        let safeName = SafeFilename.sanitize(item.filename, fallback: item.id)
        let itemDirectory = OrganizeExportDirectory.exportDirectory(
            base: scopedDirectory,
            selectedDirectoryName: request.exportDirectory.lastPathComponent,
            creationDate: asset.creationDate ?? asset.modificationDate ?? Date(),
            organizeByYearEnabled: options.organizeByYear
        )
        try? FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)

        do {
            // A previous run may have exported this asset but failed to move it: reuse that
            // file instead of writing a numbered duplicate.
            let alreadyExported = PhotoAssetExporter.existingExport(
                ofAssetIdentifier: asset.localIdentifier,
                filename: safeName,
                in: itemDirectory
            ) != nil
            if !alreadyExported {
                guard let destination = uniqueDestinationURL(
                    directory: itemDirectory,
                    filename: safeName,
                    fileManager: .default
                ) else {
                    return .failed("Invalid export path")
                }
                try await exportAsset(asset, to: destination, options: options)
            }
            try await request.photosService.moveAsset(
                asset,
                fromSourceAlbum: request.sourceAlbum,
                toAlbumNamed: request.targetAlbumTitle
            )
            return .moved
        } catch is OrganizeSkipError {
            return .skipped(OrganizeSkipError.iCloudOnly.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func finishWithAccessError(items: [MediaItem]) {
        failures = [
            OrganizeFailure(
                filename: "",
                message: "Could not access the export folder. Choose it again when organizing."
            )
        ]
        progress = OrganizeProgress(
            current: 0,
            total: items.count,
            filename: "",
            failedCount: items.count,
            skippedCount: 0,
            movedCount: 0,
            isComplete: true,
            wasCancelled: false
        )
        isRunning = false
        exportTask = nil
        onFinished = nil
        runID = nil
    }

    private func exportAsset(_ asset: PHAsset, to destination: URL, options: ExportOptions) async throws {
        do {
            try await PhotoAssetExporter.writeResources(
                for: asset,
                to: destination,
                preferEdited: options.preferEdited,
                includeCompanions: options.includeCompanions
            )
        } catch let error as PhotoAssetExportError {
            switch error {
            case .noResource:
                throw OrganizeExportError.noResource
            case .iCloudOnly:
                throw OrganizeSkipError.iCloudOnly
            }
        }
    }

    private func uniqueDestinationURL(
        directory: URL,
        filename: String,
        fileManager: FileManager
    ) -> URL? {
        guard var candidate = SafeFilename.fileURL(in: directory, filename: filename, fallback: "photo") else {
            return nil
        }

        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            guard let next = SafeFilename.fileURL(in: directory, filename: newName, fallback: "photo") else {
                return nil
            }
            candidate = next
            counter += 1
        }
        return candidate
    }

    private func fileManagerExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

private struct ExportOptions {
    let preferEdited: Bool
    let includeCompanions: Bool
    let organizeByYear: Bool
}

private struct OrganizeRequest {
    let sourceAlbum: PhotoAlbum
    let targetAlbumTitle: String
    let exportDirectory: URL
    let photosService: PhotosService
}

private enum OrganizeItemOutcome {
    case moved
    case skipped(String)
    case failed(String)
}

private struct OrganizeTally {
    var processed = 0
    var moved = 0
    var skipped = 0
    var failed = 0
    var failures: [OrganizeFailure] = []

    mutating func record(_ outcome: OrganizeItemOutcome, for item: MediaItem) {
        processed += 1
        switch outcome {
        case .moved:
            moved += 1
        case .skipped(let message):
            skipped += 1
            failures.append(OrganizeFailure(filename: item.filename, message: message))
        case .failed(let message):
            failed += 1
            failures.append(OrganizeFailure(filename: item.filename, message: message))
        }
    }

    func progress(total: Int, filename: String, isComplete: Bool, wasCancelled: Bool = false) -> OrganizeProgress {
        OrganizeProgress(
            current: processed,
            total: total,
            filename: filename,
            failedCount: failed,
            skippedCount: skipped,
            movedCount: moved,
            isComplete: isComplete,
            wasCancelled: wasCancelled
        )
    }
}

private enum OrganizeExportError: LocalizedError {
    case noResource

    var errorDescription: String? {
        switch self {
        case .noResource:
            return "No exportable resource found"
        }
    }
}

private enum OrganizeSkipError: LocalizedError {
    case iCloudOnly

    var errorDescription: String? {
        switch self {
        case .iCloudOnly:
            return "Not downloaded from iCloud"
        }
    }
}
