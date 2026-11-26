import Foundation

/// Top-level destination shown by `RootView` once launch onboarding is done.
enum AppRoute: Sendable, Equatable {
    case home
    case photos
    case drone
    case localPhotos
}

/// Which Photos-mode commands (menu items and their shortcuts) are available.
struct PhotosCommandState: Equatable {
    let route: AppRoute
    let hasSelectedAlbum: Bool
    let hasSelectedMedia: Bool
    let hasMedia: Bool
    let canOrganizeSelectedAlbum: Bool
    let isOrganizing: Bool
    let isLoadingAlbums: Bool

    /// Menu shortcuts are global; outside Photos mode they must not reload albums or switch
    /// the hidden album selection behind the Drone or Local Photos screens.
    private var isPhotos: Bool { route == .photos }

    var canRefreshAlbums: Bool { isPhotos && !isLoadingAlbums }
    var canSwitchAlbums: Bool { isPhotos }
    var canToggleThumbnails: Bool { isPhotos && hasSelectedAlbum }
    var canOrganize: Bool {
        isPhotos && hasSelectedAlbum && hasMedia && !isOrganizing && canOrganizeSelectedAlbum
    }
    var canQuickLook: Bool { isPhotos && hasSelectedMedia }
}
