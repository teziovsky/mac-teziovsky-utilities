import SwiftUI

/// Settings → External Drive: the two saved folders of Move to External Drive.
struct ExternalDriveSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var sourcePath: String?
    @State private var drivePath: String?

    var body: some View {
        Form {
            Section("Folders") {
                folderRow("Source folder", path: sourcePath, role: .source)
                folderRow("Drive folder", path: drivePath, role: .destination)
                Text(
                    "Files move from the source folder to the same relative path on the drive. "
                        + "Originals go to the Trash only after the copy is verified."
                )
                .font(AlbumListRowStyle.detailFont)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        // Bookmarks resolve here, not in `body`: resolving can re-store a stale bookmark.
        .onAppear(perform: reload)
    }

    private func folderRow(_ title: String, path: String?, role: ExternalDriveFolderRole) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(path.map(DroneFormat.abbreviatedPath) ?? "Not chosen")
                    .font(path == nil ? .body : .body.monospaced())
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path ?? "")
                Button("Choose…") {
                    if appState.chooseExternalDriveFolder(role) {
                        reload()
                    }
                }
            }
        }
    }

    private func reload() {
        sourcePath = Self.storedPath(.source)
        drivePath = Self.storedPath(.destination)
    }

    private static func storedPath(_ role: ExternalDriveFolderRole) -> String? {
        switch AppSettings.resolveExternalDriveFolder(role) {
        case let .resolved(url): return url.path
        case let .unavailable(path): return path
        case .notChosen: return nil
        }
    }
}
