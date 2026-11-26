import SwiftUI

/// The two window-level keys that can't be menu items: Esc (a menu can't own it) and ⌘=,
/// the unshifted "zoom in" key most keyboards send for ⌘+. Both are scoped to the main
/// window, so they stay inactive while Settings is focused. Every other shortcut lives in
/// the menu bar (`TeziovskyUtilitiesCommands`).
struct MainWindowKeyboardShortcuts: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            Button("Back") { appState.run(.escape) }
                .keyboardShortcut(.cancelAction)
            Button("Larger Thumbnails") { appState.run(.largerThumbnails) }
                .keyboardShortcut("=", modifiers: .command)
        }
        .hidden()
        .accessibilityHidden(true)
    }
}
