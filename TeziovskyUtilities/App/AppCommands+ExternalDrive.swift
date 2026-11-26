import AppKit
import Foundation

extension AppState {
    /// "No source" means the service has none: entering the mode runs `check()`, which resolves the
    /// saved folder into `sourceURL`, and ⌘O sets it.
    func externalDriveSourceNotice() -> CommandDecision? {
        externalDriveService.sourceURL == nil ? .notice("Choose the source folder first (⌘O).") : nil
    }

    /// ⌘O in Move to External Drive: picks the folder to move from, then checks it.
    func chooseExternalDriveSource(using panel: NSOpenPanel) {
        panel.title = "Choose the folder to move from"
        panel.prompt = "Check"
        panel.directoryURL = externalDriveService.sourceURL
            ?? URL(fileURLWithPath: ExternalDriveFolderRole.source.suggestedPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        externalDriveService.useSource(url)
    }
}

extension AppState {
    /// "Choose…" for a saved folder (the review's choosers and Settings): opens the panel at the suggested
    /// place, stores the folder and re-checks the workflow when it is open and idle. Returns whether one was chosen.
    @discardableResult
    func chooseExternalDriveFolder(_ role: ExternalDriveFolderRole) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = role == .source ? "Choose the folder to move from" : "Choose the folder on the drive"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: role.suggestedPath)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        AppSettings.storeExternalDriveFolder(url, role: role)
        if role == .source {
            externalDriveService.forgetSessionSource()
        }
        if route == .externalDrive, !externalDriveService.isRunning {
            externalDriveService.check()
        }
        return true
    }

    /// Reveals the drive-move log in Finder, creating it first so there is always a file to show.
    func showExternalDriveLog() {
        let log = ExternalDriveLog.shared
        log.ensureFileExists()
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
    }
}
