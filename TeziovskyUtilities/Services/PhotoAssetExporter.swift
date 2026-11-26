import Darwin
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

    private static let assetIdentifierAttribute = "com.teziovsky.utilities.photos-asset-id"

    /// Tags an exported file with its Photos asset so a re-run recognises it instead of writing
    /// a numbered duplicate (e.g. after the export succeeded but moving the asset failed).
    static func markExported(_ url: URL, assetIdentifier: String) {
        let value = Array(assetIdentifier.utf8)
        url.path.withCString { path in
            assetIdentifierAttribute.withCString { name in
                value.withUnsafeBytes { bytes in
                    _ = setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
    }

    /// An earlier export of the asset among `filename`, `filename (1)`, … in `directory`.
    static func existingExport(ofAssetIdentifier identifier: String, filename: String, in directory: URL) -> URL? {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            if exportedAssetIdentifier(of: candidate) == identifier {
                return candidate
            }
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return nil
    }

    private static func exportedAssetIdentifier(of url: URL) -> String? {
        url.path.withCString { path in
            assetIdentifierAttribute.withCString { name -> String? in
                let size = getxattr(path, name, nil, 0, 0, 0)
                guard size > 0 else { return nil }
                var buffer = [UInt8](repeating: 0, count: size)
                guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
                return String(bytes: buffer, encoding: .utf8)
            }
        }
    }

    /// iCloud download failures, recognised by error domain/code (localized messages differ
    /// per system language), including errors wrapped as `NSUnderlyingErrorKey`.
    static func isICloudDownloadFailure(_ error: NSError) -> Bool {
        if error.domain == PHPhotosErrorDomain {
            let networkCodes: Set<Int> = [
                PHPhotosError.networkAccessRequired.rawValue,
                PHPhotosError.networkError.rawValue
            ]
            if networkCodes.contains(error.code) { return true }
        }
        if error.domain == NSURLErrorDomain || error.domain.contains("CloudPhotoLibrary")
            || error.domain.contains("CloudKit") {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isICloudDownloadFailure(underlying)
        }
        // Last resort for unknown English-only wrappers.
        let message = error.localizedDescription.lowercased()
        return message.contains("icloud") || message.contains("not downloaded")
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
            markExported(destination, assetIdentifier: asset.localIdentifier)
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
                    if isICloudDownloadFailure(error as NSError) {
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
