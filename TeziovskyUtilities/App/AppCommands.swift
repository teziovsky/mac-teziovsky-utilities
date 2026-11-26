import AppKit
import Foundation
import Quartz

/// The app's keyboard commands. Each shortcut has a single owner (a menu item, or the
/// window's Esc handler) that is always enabled; when a command cannot run, its decision
/// explains why in a banner instead of the key doing nothing.
enum AppCommand: Equatable {
    case home
    case back
    case escape
    case openFolder
    case refresh
    case reveal
    case toggleSidebar
    case toggleThumbnails
    case organize
    case quickLook
    case largerThumbnails
    case smallerThumbnails
    case selectAlbum(Int)
    case nextAlbum
    case previousAlbum
    case undoFinalizeStep

    /// Name used in "only available in …" banners.
    fileprivate var title: String {
        switch self {
        case .toggleSidebar: return "The sidebar"
        case .toggleThumbnails: return "Thumbnail display"
        case .organize: return "Organize Album"
        case .quickLook: return "Quick Look"
        case .largerThumbnails, .smallerThumbnails: return "Thumbnail size"
        case .selectAlbum, .nextAlbum, .previousAlbum: return "Album switching"
        default: return "This command"
        }
    }

    fileprivate var isPhotosOnly: Bool {
        switch self {
        case .toggleSidebar, .toggleThumbnails, .organize, .quickLook, .largerThumbnails,
             .smallerThumbnails, .selectAlbum, .nextAlbum, .previousAlbum:
            return true
        default:
            return false
        }
    }
}

enum CommandDecision: Equatable {
    case perform
    case notice(String)
}

struct AppNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

// MARK: - Decisions

extension AppState {
    func decision(for command: AppCommand) -> CommandDecision {
        if isPresentingModalUI() {
            // A progress sheet is up because work is running: name the work, not the sheet.
            return .notice(busyReason() ?? "Close the open dialog or switch back to the main window first.")
        }
        if command.isPhotosOnly {
            guard route == .photos else {
                return .notice("\(command.title) is only available in Export iCloud Photos.")
            }
            return photosDecision(for: command)
        }
        switch command {
        case .home:
            return route == .home ? .perform : busyReason().map(CommandDecision.notice) ?? .perform
        case .back, .escape:
            return backDecision()
        case .openFolder:
            return openFolderDecision()
        case .refresh:
            return refreshDecision()
        case .reveal:
            return revealDecision()
        case .undoFinalizeStep:
            return undoDecision()
        default:
            return .perform
        }
    }

    /// What is running in the current mode, phrased for a banner; nil when idle.
    func busyReason() -> String? {
        switch route {
        case .home:
            return nil
        case .photos:
            guard organizeExporter.isRunning else { return nil }
            let album = organizeExporter.sourceAlbumName.map { "“\($0)”" } ?? "the album"
            return "Organizing \(album) is in progress. Use Cancel in the progress window, or wait until it finishes."
        case .localPhotos:
            guard let activity = localPhotosService.activityTitle else { return nil }
            return "\(activity) is in progress. Use Cancel, or wait until it finishes."
        case .externalDrive:
            guard let activity = externalDriveService.activityTitle else { return nil }
            return "\(activity) is in progress. Use Cancel, or wait until it finishes."
        case .drone:
            if droneWorkflow.finalizer.isRunning {
                return "A finalize step is changing files and can't be interrupted. Wait until it finishes."
            }
            if droneWorkflow.compressionSession.isRunning {
                return "HandBrake is compressing exports. Use Cancel, or wait until it finishes."
            }
            return nil
        }
    }

    private func backDecision() -> CommandDecision {
        if let busy = busyReason() { return .notice(busy) }
        switch route {
        case .home:
            return .notice("You are already on the home screen.")
        case .photos:
            return .perform
        case .localPhotos:
            if localPhotosService.workflowStep.previous != nil || localPhotosService.directory == nil {
                return .perform
            }
            return .notice("This is the first step. Press ⇧⌘H to leave — the scan results will be discarded.")
        case .externalDrive:
            return .perform
        case .drone:
            if droneWorkflow.canGoBack || droneWorkflow.phase == .validateLayout {
                return .perform
            }
            if droneWorkflow.finalizer.canUndo {
                return .notice(
                    "Files were already changed in this step. Use Undo Last Step (⌥⌘Z) to revert it, "
                        + "or ⇧⌘H to go home."
                )
            }
            return .notice("This workflow is finished. Press ⇧⌘H to go home.")
        }
    }

    private func openFolderDecision() -> CommandDecision {
        switch route {
        case .home:
            return .notice("Choose a workflow first.")
        case .photos:
            return .notice(
                "Export iCloud Photos works on your Photos library — you choose the export folder "
                    + "when you organize an album (⌘E)."
            )
        case .localPhotos, .drone, .externalDrive:
            return busyReason().map(CommandDecision.notice) ?? .perform
        }
    }

    private func refreshDecision() -> CommandDecision {
        if let busy = busyReason() { return .notice(busy) }
        switch route {
        case .home:
            return .notice("Choose a workflow first.")
        case .photos:
            if !photosService.canAccessLibrary { return .notice("Allow access to Photos first.") }
            if photosService.isLoadingAlbums { return .notice("Albums are already loading.") }
            return .perform
        case .localPhotos:
            return localPhotosService.directory == nil ? .notice("Choose a media folder first (⌘O).") : .perform
        case .externalDrive:
            return externalDriveSourceNotice() ?? .perform
        case .drone:
            guard droneWorkflow.hasProject else { return .notice("Choose a project folder first (⌘O).") }
            return droneWorkflow.canRefreshCurrentStep ? .perform : .notice("There is nothing to refresh in this step.")
        }
    }

    private func revealDecision() -> CommandDecision {
        switch route {
        case .home:
            return .notice("Choose a workflow first.")
        case .photos:
            return AppSettings.resolveExportDirectory() == nil
                ? .notice("There is no export folder yet — you choose it when you organize an album (⌘E).")
                : .perform
        case .localPhotos:
            return localPhotosService.directory == nil ? .notice("Choose a media folder first (⌘O).") : .perform
        case .externalDrive:
            return externalDriveSourceNotice() ?? .perform
        case .drone:
            return droneWorkflow.hasProject ? .perform : .notice("Choose a project folder first (⌘O).")
        }
    }

    private func undoDecision() -> CommandDecision {
        guard route == .drone else {
            return .notice("Undo Last Step is part of Organize Drone Footage.")
        }
        if let busy = busyReason() { return .notice(busy) }
        return droneWorkflow.canUndoFinalizeStep
            ? .perform
            : .notice("There is nothing to undo — no finalize step has changed files yet.")
    }

    private func photosDecision(for command: AppCommand) -> CommandDecision {
        switch command {
        case .toggleSidebar:
            return .perform
        case .organize:
            return organizeDecision()
        case .quickLook:
            return selectedMediaID == nil ? .notice("Select a photo first.") : .perform
        case .toggleThumbnails, .largerThumbnails, .smallerThumbnails:
            return thumbnailDecision(for: command)
        default:
            return albumSwitchDecision(for: command)
        }
    }

    private func thumbnailDecision(for command: AppCommand) -> CommandDecision {
        guard selectedAlbum != nil else { return .notice("Select an album first.") }
        switch command {
        case .largerThumbnails:
            return canDecreaseMediaGridColumnCount ? .perform : .notice("Thumbnails are already at their largest.")
        case .smallerThumbnails:
            return canIncreaseMediaGridColumnCount ? .perform : .notice("Thumbnails are already at their smallest.")
        default:
            return .perform
        }
    }

    private func albumSwitchDecision(for command: AppCommand) -> CommandDecision {
        switch command {
        case .selectAlbum(let index):
            return selectableAlbums.indices.contains(index)
                ? .perform
                : .notice("There is no album \(index + 1) in the list.")
        case .nextAlbum:
            guard !selectableAlbums.isEmpty else { return .notice("There are no albums to show.") }
            return canSelectNextAlbum ? .perform : .notice("This is the last album.")
        case .previousAlbum:
            guard !selectableAlbums.isEmpty else { return .notice("There are no albums to show.") }
            return canSelectPreviousAlbum ? .perform : .notice("This is the first album.")
        default:
            return .perform
        }
    }

    private func organizeDecision() -> CommandDecision {
        if let busy = busyReason() { return .notice(busy) }
        guard let album = selectedAlbum else { return .notice("Select an album first.") }
        if !photosService.canAccessLibrary { return .notice("Allow access to Photos first.") }
        if isAlbumOmittedFromOrganize(album) {
            return .notice("This album is omitted from Organize in Settings → Photos.")
        }
        if PhotosService.destinationAlbumTitle(forSourceAlbumNamed: album.name) == nil {
            return .notice("Set an album suffix in Settings → Photos first.")
        }
        if mediaItems.isEmpty {
            return .notice(isLoadingMedia ? "The album is still loading." : "This album has no photos or videos.")
        }
        return .perform
    }
}

// MARK: - Running

extension AppState {
    func run(_ command: AppCommand) {
        // Esc in a text field (e.g. the Local Media filter) first leaves the field, like in
        // Finder; only the next Esc navigates.
        if command == .escape, endTextEditingInMainWindow() {
            return
        }
        switch decision(for: command) {
        case .notice(let message):
            showNotice(message)
        case .perform:
            perform(command)
        }
    }

    func showNotice(_ message: String) {
        let notice = AppNotice(message: message)
        self.notice = notice
        if playsAlertSound {
            NSSound.beep()
        }
        if let mainWindow {
            NSAccessibility.post(
                element: mainWindow,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.notice?.id == notice.id {
                self?.notice = nil
            }
        }
    }

    private func endTextEditingInMainWindow() -> Bool {
        guard let mainWindow, let editor = mainWindow.firstResponder as? NSText, editor.isFieldEditor else {
            return false
        }
        return mainWindow.makeFirstResponder(nil)
    }

    /// Whether a sheet, dialog, panel or another window (e.g. Settings) is in front of the
    /// main window. Quick Look's panel does not count: it is part of browsing.
    func modalUIIsPresented() -> Bool {
        guard let mainWindow else { return false }
        if NSApp.modalWindow != nil || mainWindow.attachedSheet != nil {
            return true
        }
        if let keyWindow = NSApp.keyWindow, keyWindow !== mainWindow, !(keyWindow is QLPreviewPanel) {
            return true
        }
        return false
    }

    var refreshTitle: String {
        switch route {
        case .localPhotos: return "Rescan Folder"
        case .externalDrive: return "Check Again"
        case .drone: return "Refresh Step"
        default: return "Refresh Albums"
        }
    }

    var openFolderTitle: String {
        switch route {
        case .drone: return "Open Project Folder…"
        case .externalDrive: return "Choose Source Folder for This Session…"
        default: return "Open Media Folder…"
        }
    }

    private func perform(_ command: AppCommand) {
        switch command {
        case .home:
            leaveCurrentMode()
        case .back, .escape:
            goBackOneLevel()
        case .openFolder:
            openFolder()
        case .refresh:
            refreshCurrentMode()
        case .reveal:
            revealCurrentFolder()
        case .undoFinalizeStep:
            droneWorkflow.undoLastFinalizeStep()
        default:
            performPhotosCommand(command)
        }
    }

    private func leaveCurrentMode() {
        switch route {
        case .drone: droneWorkflow.reset()
        case .localPhotos: localPhotosService.reset()
        case .externalDrive: externalDriveService.reset()
        case .home, .photos: break
        }
        if QuickLookHelper.isPanelVisible {
            QuickLookHelper.closePreview()
        }
        goHome()
    }

    private func goBackOneLevel() {
        switch route {
        case .home:
            break
        case .photos:
            if QuickLookHelper.isPanelVisible {
                QuickLookHelper.closePreview()
            } else {
                photosEscapeBack()
            }
        case .localPhotos:
            if let previous = localPhotosService.workflowStep.previous {
                localPhotosService.workflowStep = previous
            } else {
                leaveCurrentMode()
            }
        case .externalDrive:
            if !externalDriveService.goBack() {
                leaveCurrentMode()
            }
        case .drone:
            if droneWorkflow.canGoBack {
                droneWorkflow.goBack()
            } else {
                leaveCurrentMode()
            }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        switch route {
        case .drone:
            panel.prompt = "Choose"
            panel.message = "Select the drone project folder."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            droneWorkflow.loadProject(projectDirectory: url, config: AppSettings.droneFinalizeConfig)
        case .localPhotos:
            panel.title = "Choose a media folder"
            panel.prompt = "Scan"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            localPhotosService.scan(directory: url)
        case .externalDrive:
            chooseExternalDriveSource(using: panel)
        case .home, .photos:
            break
        }
    }

    private func refreshCurrentMode() {
        switch route {
        case .photos:
            Task { await photosService.reloadAlbums() }
        case .localPhotos:
            if let directory = localPhotosService.directory {
                localPhotosService.scan(directory: directory)
            }
        case .externalDrive:
            externalDriveService.check()
        case .drone:
            droneWorkflow.refreshCurrentStep()
        case .home:
            break
        }
    }

    private func revealCurrentFolder() {
        let folder: URL?
        switch route {
        case .photos: folder = AppSettings.resolveExportDirectory()
        case .localPhotos: folder = localPhotosService.directory
        case .externalDrive: folder = externalDriveService.sourceURL
        case .drone: folder = droneWorkflow.projectDirectoryPath.map { URL(fileURLWithPath: $0) }
        case .home: folder = nil
        }
        if let folder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func performPhotosCommand(_ command: AppCommand) {
        switch command {
        case .toggleSidebar:
            toggleSidebarVisibility()
        case .toggleThumbnails:
            toggleThumbnailDisplayMode()
        case .organize:
            promptExportDirectoryAndOrganize()
        case .quickLook:
            if QuickLookHelper.isPanelVisible {
                QuickLookHelper.closePreview()
            } else {
                Task { await previewSelectedMedia() }
            }
        case .largerThumbnails:
            decreaseMediaGridColumnCount()
        case .smallerThumbnails:
            increaseMediaGridColumnCount()
        default:
            switchAlbum(for: command)
        }
    }

    private func switchAlbum(for command: AppCommand) {
        switch command {
        case .selectAlbum(let index):
            Task { await selectAlbum(at: index) }
        case .nextAlbum:
            Task { await selectNextAlbum() }
        case .previousAlbum:
            Task { await selectPreviousAlbum() }
        default:
            break
        }
    }
}
