import SwiftUI

/// Window-level keys that can't be menu items, scoped to the main window so they stay
/// inactive while Settings is focused. Every other shortcut lives in the menu bar
/// (`TeziovskyUtilitiesCommands`).
///
/// - Esc: a menu item can't own it.
/// - ⌘=: the unshifted "zoom in" key most keyboards send for ⌘+.
/// - ⌘↓ / ⌘↑: switch albums, bound only while Export iCloud Photos is open (it has no text
///   fields), so the keys keep moving the caret in text fields everywhere else.
struct MainWindowKeyboardShortcuts: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            Button("Back") { appState.run(.escape) }
                .keyboardShortcut(.cancelAction)
            Button("Larger Thumbnails") { appState.run(.largerThumbnails) }
                .keyboardShortcut("=", modifiers: .command)
            if appState.route == .photos {
                Button("Next Album") { appState.run(.nextAlbum) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Album") { appState.run(.previousAlbum) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}
