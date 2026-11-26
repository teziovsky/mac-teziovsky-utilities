import SwiftUI

struct AlbumSidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch appState.photosService.authorizationState {
            case .notDetermined:
                AlbumsLoadingView(message: "Connecting to Photos…")
            case .authorized:
                albumList
            case .limited:
                PhotosLimitedAccessView()
            case .denied, .restricted:
                PhotosAccessUnavailableView(
                    title: "Photos Access Required",
                    description: "Allow \(AppBranding.appName) to access your Photos library in System Settings."
                )
            }
        }
        .frame(minWidth: 280, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(min: 260, ideal: 280)
        .overlay(alignment: .top) {
            if let error = appState.photosService.errorMessage {
                Text(error)
                    .font(AlbumListRowStyle.detailFont)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
    }

    @ViewBuilder
    private var albumList: some View {
        if appState.photosService.isLoadingAlbums && appState.selectableAlbums.isEmpty {
            AlbumsLoadingView()
        } else if appState.selectableAlbums.isEmpty {
            let message = OrganizeCompleteMessaging.sidebar(
                allAlbums: appState.photosService.albums,
                selectableAlbums: appState.selectableAlbums
            )
            OrganizeCompleteEmptyView(title: message.title, description: message.description)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                ForEach(appState.selectableAlbums) { album in
                    Label(album.name, systemImage: AlbumListRowStyle.sidebarIconName)
                        .badge(album.mediaCount)
                        .help(album.mediaSummary)
                        .tag(album.id)
                        .accessibilityHint(album.mediaSummary)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if appState.photosService.isLoadingAlbums {
                    ProgressView()
                        .controlSize(.regular)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Native list selection: click, arrow keys and type-to-select. Deselecting is done with
    /// Esc or the Back button, as clicking a selected row keeps it selected.
    private var selection: Binding<String?> {
        Binding(
            get: { appState.selectedAlbum?.id },
            set: { id in
                guard id != appState.selectedAlbum?.id else { return }
                appState.selectAlbumFromSidebar(appState.selectableAlbums.first { $0.id == id })
            }
        )
    }
}
