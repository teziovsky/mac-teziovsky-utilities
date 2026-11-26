import AppKit
import SwiftUI

@main
struct TeziovskyUtilitiesApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 700)
                .task {
                    await appState.bootstrap()
                }
        }
        .windowStyle(.automatic)
        .commands {
            TeziovskyUtilitiesCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

/// Every shortcut in the app lives here, in the menu bar, so it works the same way in each
/// mode. Items stay enabled: when a command can't run right now, `AppState.run` shows a
/// banner that says why instead of the key silently doing nothing.
private struct TeziovskyUtilitiesCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(appState.openFolderTitle) { appState.run(.openFolder) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Reveal in Finder") { appState.run(.reveal) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .undoRedo) {
            Button("Undo Last Finalize Step") { appState.run(.undoFinalizeStep) }
                .keyboardShortcut("z", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { appState.run(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button(appState.refreshTitle) { appState.run(.refresh) }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Toggle Thumbnail Display") { appState.run(.toggleThumbnails) }
                .keyboardShortcut("t", modifiers: .command)
            Button("Larger Thumbnails") { appState.run(.largerThumbnails) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Thumbnails") { appState.run(.smallerThumbnails) }
                .keyboardShortcut("-", modifiers: .command)

            Divider()

            Button("Quick Look") { appState.run(.quickLook) }
                .keyboardShortcut("y", modifiers: .command)
            Button("Organize Album…") { appState.run(.organize) }
                .keyboardShortcut("e", modifiers: .command)
        }

        CommandMenu("Go") {
            Button("Back") { appState.run(.back) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Home") { appState.run(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }

        CommandMenu("Albums") {
            ForEach(0..<9, id: \.self) { index in
                Button(albumTitle(at: index)) { appState.run(.selectAlbum(index)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }

            Divider()

            // ⌘↓ / ⌘↑ are bound in the Photos window only (MainWindowKeyboardShortcuts): as
            // menu shortcuts they would take caret movement away from every text field.
            Button("Next Album") { appState.run(.nextAlbum) }
            Button("Previous Album") { appState.run(.previousAlbum) }
        }
    }

    private func albumTitle(at index: Int) -> String {
        let albums = appState.selectableAlbums
        return albums.indices.contains(index) ? albums[index].name : "Album \(index + 1)"
    }
}
