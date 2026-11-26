import Foundation
import Photos

enum PhotosAuthorizationState: Sendable {
    case authorized
    case limited
    case denied
    case restricted
    case notDetermined
}

enum PhotosServiceError: LocalizedError, Sendable {
    case accessDenied
    case limitedAccess
    case albumNotFound(String)
    case organizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Photos library access was denied. Grant access in System Settings → Privacy & Security → Photos."
        case .limitedAccess:
            return "Full Photos library access is required to browse albums and organize. Grant full access in System Settings → Privacy & Security → Photos."
        case .albumNotFound(let name):
            return "Album \"\(name)\" was not found in Photos."
        case .organizeFailed(let message):
            return message
        }
    }
}

@MainActor
final class PhotosService: NSObject, ObservableObject {
    @Published private(set) var authorizationState: PhotosAuthorizationState = .notDetermined
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var isLoadingAlbums = false
    @Published var errorMessage: String?

    private var changeObserverRegistered = false
    /// Counted so overlapping Organize runs (cancel + restart) cannot end each other's deferral.
    private var albumReloadDeferrals = 0
    private var albumIdentifiersByTitle: [String: String] = [:]
    private var pendingLibraryReload: Task<Void, Never>?

    override init() {
        super.init()
        authorizationState = mapStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        registerChangeObserverIfNeeded()
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationState = mapStatus(status)
        registerChangeObserverIfNeeded()
        guard canAccessLibrary else { return }
        await reloadAlbums()
    }

    /// Reads the current authorization status without prompting (so the app can show its
    /// own explainer before triggering the system dialog). Reloads albums if already authorized.
    func refreshAuthorizationStatus() async {
        authorizationState = mapStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        registerChangeObserverIfNeeded()
        guard canAccessLibrary else { return }
        if albums.isEmpty {
            await reloadAlbums()
        }
    }

    var needsAuthorizationPrompt: Bool {
        authorizationState == .notDetermined
    }

    var canAccessLibrary: Bool {
        authorizationState == .authorized
    }

    func reloadAlbums() async {
        guard canAccessLibrary else { return }
        isLoadingAlbums = true
        errorMessage = nil
        defer { isLoadingAlbums = false }

        let excludedSuffix = AppSettings.excludedAlbumSuffix
        albums = await Task.detached(priority: .userInitiated) {
            Self.collectAlbums(excludedSuffix: excludedSuffix)
        }.value
    }

    /// Coalesces `photoLibraryDidChange` reloads while Organize is moving assets (one refresh at `endDeferringAlbumReloadFromLibraryChanges`).
    func beginDeferringAlbumReloadFromLibraryChanges() {
        albumReloadDeferrals += 1
    }

    func endDeferringAlbumReloadFromLibraryChanges() async {
        albumReloadDeferrals = max(albumReloadDeferrals - 1, 0)
        guard albumReloadDeferrals == 0 else { return }
        await reloadAlbums()
    }

    /// Items and their assets, fetched in one background pass (the grid needs both).
    func albumContents(for album: PhotoAlbum) async throws -> AlbumContents {
        guard canAccessLibrary else {
            if authorizationState == .limited {
                throw PhotosServiceError.limitedAccess
            }
            throw PhotosServiceError.accessDenied
        }
        guard let collection = Self.fetchCollection(identifier: album.collectionIdentifier) else {
            throw PhotosServiceError.albumNotFound(album.name)
        }
        return await Task.detached(priority: .userInitiated) {
            Self.fetchContents(in: collection)
        }.value
    }

    static func destinationAlbumTitle(forSourceAlbumNamed sourceName: String) -> String? {
        destinationAlbumTitle(forSourceAlbumNamed: sourceName, suffix: AppSettings.excludedAlbumSuffix)
    }

    /// The "done" album name. nil for a blank suffix: it would equal the source album, so every
    /// item would be exported and then fail to move.
    nonisolated static func destinationAlbumTitle(forSourceAlbumNamed sourceName: String, suffix: String) -> String? {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : sourceName + trimmed
    }

    /// The Photos folder new "done" albums go into. nil for a blank setting: they stay at the top level.
    nonisolated static func doneAlbumsFolderTitle(fromSetting setting: String) -> String? {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func moveAsset(
        _ asset: PHAsset,
        fromSourceAlbum sourceAlbum: PhotoAlbum,
        toAlbumNamed targetTitle: String
    ) async throws {
        guard canAccessLibrary else {
            if authorizationState == .limited {
                throw PhotosServiceError.limitedAccess
            }
            throw PhotosServiceError.accessDenied
        }
        guard targetTitle != sourceAlbum.name else {
            throw PhotosServiceError.organizeFailed("Destination album name matches the source album.")
        }
        guard let sourceCollection = Self.fetchCollection(identifier: sourceAlbum.collectionIdentifier) else {
            throw PhotosServiceError.albumNotFound(sourceAlbum.name)
        }

        try await Self.performMove(
            asset: asset,
            sourceCollection: sourceCollection,
            targetCollection: try await targetCollection(titled: targetTitle)
        )
    }

    /// Resolves the "done" album once per title instead of scanning every album per asset.
    private func targetCollection(titled title: String) async throws -> PHAssetCollection {
        if let identifier = albumIdentifiersByTitle[title],
           let cached = Self.fetchCollection(identifier: identifier) {
            return cached
        }
        let collection: PHAssetCollection
        if let existing = Self.fetchCollection(title: title) {
            collection = existing
        } else {
            collection = try await Self.createAlbum(
                title: title,
                inFolderTitled: Self.doneAlbumsFolderTitle(fromSetting: AppSettings.doneAlbumsFolderName)
            )
        }
        albumIdentifiersByTitle[title] = collection.localIdentifier
        return collection
    }

    private func registerChangeObserverIfNeeded() {
        guard canAccessLibrary, !changeObserverRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        changeObserverRegistered = true
    }

    private func mapStatus(_ status: PHAuthorizationStatus) -> PhotosAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    nonisolated private static func collectAlbums(excludedSuffix: String) -> [PhotoAlbum] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var results: [PhotoAlbum] = []
        results.reserveCapacity(collections.count)

        var index = 0
        while index < collections.count {
            let album = collections.object(at: index)
            if let photoAlbum = makePhotoAlbum(from: album, excludedSuffix: excludedSuffix) {
                results.append(photoAlbum)
            }
            index += 1
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func isSharedAlbum(_ album: PHAssetCollection) -> Bool {
        switch album.assetCollectionSubtype {
        case .albumCloudShared, .albumMyPhotoStream:
            return true
        default:
            return false
        }
    }

    nonisolated private static func makePhotoAlbum(
        from album: PHAssetCollection,
        excludedSuffix: String
    ) -> PhotoAlbum? {
        guard !isSharedAlbum(album) else { return nil }

        let name = album.localizedTitle ?? "Untitled"
        guard AlbumNameFilter.shouldInclude(albumName: name, excludedSuffix: excludedSuffix) else { return nil }

        let assets = PHAsset.fetchAssets(in: album, options: nil)
        let mediaCount = assets.count
        guard mediaCount > 0 else { return nil }
        let videoOptions = PHFetchOptions()
        videoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let videoCount = PHAsset.fetchAssets(in: album, options: videoOptions).count

        return PhotoAlbum(
            id: album.localIdentifier,
            name: name,
            mediaCount: mediaCount,
            photoCount: mediaCount - videoCount,
            videoCount: videoCount,
            collectionIdentifier: album.localIdentifier
        )
    }

    nonisolated private static func fetchCollection(identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        ).firstObject
    }

    nonisolated private static func fetchCollection(title: String) -> PHAssetCollection? {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var index = 0
        while index < collections.count {
            let collection = collections.object(at: index)
            if collection.localizedTitle == title {
                return collection
            }
            index += 1
        }
        return nil
    }

    nonisolated private static func performMove(
        asset: PHAsset,
        sourceCollection: PHAssetCollection,
        targetCollection: PHAssetCollection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: targetCollection)?
                    .addAssets([asset] as NSArray)
                PHAssetCollectionChangeRequest(for: sourceCollection)?
                    .removeAssets([asset] as NSArray)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: PhotosServiceError.organizeFailed("Photos could not update albums.")
                    )
                }
            }
        }
    }

    nonisolated private static func fetchContents(in collection: PHAssetCollection) -> AlbumContents {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(in: collection, options: options)
        var items: [MediaItem] = []
        var assetsByID: [String: PHAsset] = [:]
        items.reserveCapacity(assets.count)
        assetsByID.reserveCapacity(assets.count)

        var index = 0
        while index < assets.count {
            let asset = assets.object(at: index)
            items.append(
                MediaItem(
                    id: asset.localIdentifier,
                    filename: Self.filename(for: asset),
                    isVideo: asset.mediaType == .video,
                    creationDate: asset.creationDate,
                    duration: asset.mediaType == .video ? asset.duration : nil
                )
            )
            assetsByID[asset.localIdentifier] = asset
            index += 1
        }
        return AlbumContents(items: items, assetsByID: assetsByID)
    }

    nonisolated private static func filename(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let original = resources.first(where: { $0.type == .photo || $0.type == .video || $0.type == .fullSizeVideo }) {
            return SafeFilename.sanitize(original.originalFilename, fallback: "photo")
        }
        let ext = asset.mediaType == .video ? "mov" : "jpg"
        return SafeFilename.sanitize(
            "\(asset.localIdentifier.replacingOccurrences(of: "/", with: "_")).\(ext)",
            fallback: "photo.\(ext)"
        )
    }
}

extension PhotosService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            scheduleLibraryReload()
        }
    }

    /// iCloud sync delivers bursts of changes; reload once the burst settles instead of per
    /// change, and retry rather than drop a change that arrives mid-reload.
    private func scheduleLibraryReload() {
        pendingLibraryReload?.cancel()
        pendingLibraryReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, !Task.isCancelled, canAccessLibrary, albumReloadDeferrals == 0 else { return }
            if isLoadingAlbums {
                scheduleLibraryReload()
                return
            }
            await reloadAlbums()
        }
    }
}

/// An album's grid items and their assets. PHAsset is immutable and safe to read from any thread.
struct AlbumContents: @unchecked Sendable {
    let items: [MediaItem]
    let assetsByID: [String: PHAsset]
}

// MARK: - Creating "done" albums

extension PhotosService {
    private typealias AlbumContinuation = CheckedContinuation<PHAssetCollection, Error>

    nonisolated private static func fetchFolder(title: String) -> PHCollectionList? {
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
        var index = 0
        while index < folders.count {
            let folder = folders.object(at: index)
            if folder.localizedTitle == title {
                return folder
            }
            index += 1
        }
        return nil
    }

    /// Creates the album inside `folderTitle` (creating the folder when it doesn't exist) in one
    /// change, so the album never shows up at the top level first.
    nonisolated private static func createAlbum(
        title: String,
        inFolderTitled folderTitle: String?
    ) async throws -> PHAssetCollection {
        let existingFolder = folderTitle.flatMap { fetchFolder(title: $0) }
        return try await withCheckedThrowingContinuation { (continuation: AlbumContinuation) in
            var createdIdentifier: String?
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                let placeholder = request.placeholderForCreatedAssetCollection
                createdIdentifier = placeholder.localIdentifier
                if let existingFolder {
                    PHCollectionListChangeRequest(for: existingFolder)?
                        .addChildCollections([placeholder] as NSArray)
                } else if let folderTitle {
                    PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folderTitle)
                        .addChildCollections([placeholder] as NSArray)
                }
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success,
                      let createdIdentifier,
                      let collection = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [createdIdentifier],
                        options: nil
                      ).firstObject else {
                    continuation.resume(
                        throwing: PhotosServiceError.organizeFailed("Could not create album \"\(title)\".")
                    )
                    return
                }
                continuation.resume(returning: collection)
            }
        }
    }
}
