import SwiftUI

struct PhotosModeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.columnVisibility) {
            AlbumSidebarView()
        } detail: {
            if appState.selectedAlbum != nil {
                MediaGridView()
            } else if appState.photosService.canAccessLibrary && appState.selectableAlbums.isEmpty {
                let message = OrganizeCompleteMessaging.sidebar(
                    allAlbums: appState.photosService.albums,
                    selectableAlbums: appState.selectableAlbums
                )
                OrganizeCompleteEmptyView(title: message.title, description: message.description)
            } else {
                ContentUnavailableView(
                    "Select an Album",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        "Choose an album from the sidebar to review photos before organizing.")
                )
            }
        }
        .navigationTitle(mainToolbarTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.run(.home)
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Back to the home screen (⇧⌘H)")
            }

            albumNavigationHeader
            if appState.selectedAlbum != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        appState.run(.largerThumbnails)
                    } label: {
                        Label("Larger Thumbnails", systemImage: "plus")
                    }
                    .help("Fewer columns, larger thumbnails (⌘+)")
                    .disabled(!appState.canDecreaseMediaGridColumnCount)

                    Button {
                        appState.run(.smallerThumbnails)
                    } label: {
                        Label("Smaller Thumbnails", systemImage: "minus")
                    }
                    .help("More columns, smaller thumbnails (⌘−)")
                    .disabled(!appState.canIncreaseMediaGridColumnCount)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.run(.toggleThumbnails)
                } label: {
                    Label(
                        appState.thumbnailDisplayMode.toolbarLabel,
                        systemImage: appState.thumbnailDisplayMode.toolbarIcon
                    )
                }
                .help("Toggle square cropped or full aspect ratio thumbnails (⌘T)")
                .disabled(appState.selectedAlbum == nil)

                Button {
                    appState.run(.refresh)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload albums from Photos (⌘R)")
                .disabled(appState.photosService.isLoadingAlbums)
            }

            if appState.selectedAlbum != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Organize") {
                        appState.run(.organize)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        appState.mediaItems.isEmpty
                            || appState.organizeExporter.isRunning
                            || !appState.canOrganizeSelectedAlbum
                    )
                    .help(organizeHelp)
                }
            }
        }
        .sheet(isPresented: $appState.showOrganizeSheet) {
            OrganizeProgressView()
                .environmentObject(appState)
        }
        .alert("Quick Look Failed", isPresented: quickLookErrorBinding) {
            Button("OK", role: .cancel) {
                appState.quickLookError = nil
            }
        } message: {
            if let error = appState.quickLookError {
                Text(error)
            }
        }
    }

    private var organizeHelp: String {
        if appState.canOrganizeSelectedAlbum {
            return "Export, move to album with suffix, and remove from source (⌘E)"
        }
        if AppSettings.excludedAlbumSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Set an album suffix in Settings → Photos; organized items move to that album"
        }
        return "This album is omitted from Organize in Photos settings"
    }

    private var mainToolbarTitle: String {
        appState.selectedAlbum == nil ? AppBranding.photosModeTitle : ""
    }

    @ToolbarContentBuilder
    private var albumNavigationHeader: some ToolbarContent {
        if let album = appState.selectedAlbum {
            if #available(macOS 26.0, *) {
                ToolbarItemGroup(placement: .navigation) {
                    albumBackButton
                }

                ToolbarItem(placement: .navigation) {
                    albumTitleHeader(album)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 10) {
                        albumBackButton
                        albumTitleHeader(album)
                    }
                }
            }
        }
    }

    private var albumBackButton: some View {
        Button {
            Task { await appState.selectAlbum(nil) }
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .labelStyle(.iconOnly)
        .help("Deselect album")
    }

    private func albumTitleHeader(_ album: PhotoAlbum) -> some View {
        VStack(alignment: .leading, spacing: AlbumListRowStyle.labelSpacing) {
            Text(album.name)
                .font(AlbumListRowStyle.navigationAlbumTitleFont)
            Text(appState.selectedAlbumMediaSummary ?? album.mediaSummary)
                .font(AlbumListRowStyle.navigationAlbumDetailFont)
                .foregroundStyle(.secondary)
        }
    }

    private var quickLookErrorBinding: Binding<Bool> {
        Binding(
            get: { appState.quickLookError != nil },
            set: { if !$0 { appState.quickLookError = nil } }
        )
    }
}
