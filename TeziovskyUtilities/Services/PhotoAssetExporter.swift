import Foundation
import Photos

/// Which asset resources an export writes: one primary file plus optional companions
/// (Live Photo motion, RAW alternate) saved next to it.
struct PhotoExportResourcePlan: Equatable, Sendable {
    let primary: PHAssetResourceType
    let companions: [PHAssetResourceType]
}

/// The PhotoKit facts post-export processing needs, decoupled from `PHAsset` for testing.
struct ExportedResourceInfo {
    let creationDate: Date?
    let modificationDate: Date?
}

enum PhotoAssetExporter {
    /// Chooses the resources to export. Bytes are always written exactly as PhotoKit stores
    /// them; `preferEdited` only picks the edited render over the unmodified original.
    static func resourcePlan(
        available: [PHAssetResourceType],
        mediaType: PHAssetMediaType,
        preferEdited: Bool,
        includeCompanions: Bool
    ) -> PhotoExportResourcePlan? {
        let preferences: [PHAssetResourceType]
        switch mediaType {
        case .video:
            preferences = preferEdited ? [.fullSizeVideo, .video] : [.video, .fullSizeVideo]
        case .image:
            preferences = preferEdited
                ? [.fullSizePhoto, .photo, .alternatePhoto]
                : [.photo, .alternatePhoto, .fullSizePhoto]
        default:
            preferences = []
        }
        guard let primary = preferences.first(where: available.contains) ?? available.first else {
            return nil
        }
        guard includeCompanions, mediaType == .image else {
            return PhotoExportResourcePlan(primary: primary, companions: [])
        }

        var companions: [PHAssetResourceType] = []
        // Live Photo motion matching the exported still (edited still → edited motion).
        let motion: [PHAssetResourceType] = primary == .fullSizePhoto
            ? [.fullSizePairedVideo, .pairedVideo]
            : [.pairedVideo]
        if let video = motion.first(where: available.contains) {
            companions.append(video)
        }
        // RAW+JPEG pairs keep the RAW next to the JPEG.
        if primary != .alternatePhoto, available.contains(.alternatePhoto) {
            companions.append(.alternatePhoto)
        }
        return PhotoExportResourcePlan(primary: primary, companions: companions)
    }

    /// Companions share the primary file's (possibly collision-renamed) base name so Photos
    /// and other tools can re-pair them, e.g. `IMG_0001 (1).HEIC` + `IMG_0001 (1).MOV`.
    static func companionFilename(primaryDestination: URL, companionOriginalFilename: String) -> String {
        let base = primaryDestination.deletingPathExtension().lastPathComponent
        let ext = (companionOriginalFilename as NSString).pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Writes the planned resources for `asset`; returns every file written (primary first).
    /// All-or-nothing: if any resource fails, the files already written for this asset are
    /// removed so a retry does not leave numbered duplicates behind.
    @discardableResult
    static func writeResources(
        for asset: PHAsset,
        to destination: URL,
        preferEdited: Bool,
        includeCompanions: Bool
    ) async throws -> [URL] {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let plan = resourcePlan(
            available: resources.map(\.type),
            mediaType: asset.mediaType,
            preferEdited: preferEdited,
            includeCompanions: includeCompanions
        ), let primary = resources.first(where: { $0.type == plan.primary }) else {
            throw PhotoAssetExportError.noResource
        }

        // Cleanup below deletes what this call wrote, so it must never adopt a pre-existing file.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        var written: [URL] = []
        do {
            written.append(destination)
            try await writeData(for: primary, to: destination)
            try finalizeExportedFile(
                at: destination,
                info: ExportedResourceInfo(creationDate: asset.creationDate, modificationDate: asset.modificationDate)
            )

            // Companions inherit the primary's capture time so the pair stays in sync.
            let primaryCreated = try destination.resourceValues(forKeys: [.creationDateKey]).creationDate
            for type in plan.companions {
                guard let resource = resources.first(where: { $0.type == type }) else { continue }
                let name = companionFilename(
                    primaryDestination: destination,
                    companionOriginalFilename: resource.originalFilename
                )
                let companionURL = uniqueSibling(named: name, of: destination)
                written.append(companionURL)
                try await writeData(for: resource, to: companionURL)
                let created = primaryCreated ?? asset.creationDate ?? Date()
                try FileDatePreservation.applyFileDates(
                    to: companionURL,
                    created: created,
                    modified: asset.modificationDate ?? created
                )
            }
            return written
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Writes a single file for previewing (no companions).
    static func writePreviewResource(for asset: PHAsset, to destination: URL, preferEdited: Bool) async throws {
        try await writeResources(for: asset, to: destination, preferEdited: preferEdited, includeCompanions: false)
    }

    /// Post-processing after the resource bytes are on disk. Never rewrites the file's
    /// contents: only Finder Created/Modified are set, from the file's own EXIF capture time
    /// when available.
    static func finalizeExportedFile(at url: URL, info: ExportedResourceInfo) throws {
        let created = FileDatePreservation.canonicalCreationDate(
            fallback: info.creationDate ?? info.modificationDate,
            fileURL: url
        )
        try FileDatePreservation.applyFileDates(
            to: url,
            created: created,
            modified: info.modificationDate ?? created
        )
    }

    private static func uniqueSibling(named name: String, of url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    private static func writeData(for resource: PHAssetResource, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    let message = (error as NSError).localizedDescription.lowercased()
                    if message.contains("cloud") || message.contains("not downloaded") {
                        continuation.resume(throwing: PhotoAssetExportError.iCloudOnly)
                        return
                    }
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum PhotoAssetExportError: LocalizedError {
    case noResource
    case iCloudOnly

    var errorDescription: String? {
        switch self {
        case .noResource:
            return "No exportable resource found"
        case .iCloudOnly:
            return "Not downloaded from iCloud"
        }
    }
}
