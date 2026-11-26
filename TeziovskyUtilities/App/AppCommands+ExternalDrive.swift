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
