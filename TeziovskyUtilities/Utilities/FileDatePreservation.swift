import Darwin
import Foundation
import ImageIO
import Photos

enum FileDatePreservation {
    /// The capture time Finder "Created" should show: the file's own EXIF date (offset-aware)
    /// when present, otherwise the Photos library date.
    static func canonicalCreationDate(fallback: Date?, fileURL: URL) -> Date {
        if let exifDate = readExifOriginalDate(from: fileURL) {
            return exifDate
        }
        return fallback ?? Date()
    }

    /// Copies the source file's creation (birth) and modification dates onto the destination file.
    /// Used by the drone finalize step so a compressed file inherits its original's Finder dates.
    static func copyFileDates(from sourceURL: URL, to destinationURL: URL) throws {
        let values = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let created = values.creationDate ?? values.contentModificationDate ?? Date()
        let modified = values.contentModificationDate ?? created
        try applyFileDates(to: destinationURL, created: created, modified: modified)
    }

    /// Updates Finder's "Date Created" without changing the file's content modification date.
    static func applyCreationDate(_ created: Date, to url: URL) throws {
        let originalModified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var didApply = false
        var lastError: Error?

        do {
            try setAPFSBirthTime(url: url, created: created)
            didApply = true
        } catch {
            lastError = error
        }

        do {
            var values = URLResourceValues()
            values.creationDate = created
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            didApply = true
        } catch {
            lastError = error
        }

        do {
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
            didApply = true
        } catch {
            lastError = error
        }

        if let originalModified {
            var didRestore = false
            var restoreError: Error?
            do {
                var values = URLResourceValues()
                values.contentModificationDate = originalModified
                var mutableURL = url
                try mutableURL.setResourceValues(values)
                didRestore = true
            } catch {
                restoreError = error
            }
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: originalModified],
                    ofItemAtPath: url.path
                )
                didRestore = true
            } catch {
                restoreError = error
            }
            if !didRestore {
                throw restoreError ?? POSIXError(.EINVAL)
            }
        }

        if !didApply {
            throw lastError ?? POSIXError(.EINVAL)
        }
    }

    static func applyCreationDate(
        _ created: Date,
        preservingModificationDate modified: Date,
        to url: URL
    ) throws {
        try applyFileDates(to: url, created: created, modified: modified)
    }

    /// Rewrites every existing EXIF/TIFF creation field to `date` **without re-encoding the
    /// image data**: the container is copied with `CGImageDestinationCopyImageSource`, so pixels,
    /// auxiliary images (depth, gain maps) and other metadata stay byte-for-byte intact.
    ///
    /// Each field is written as local time in its own EXIF offset when one exists; offset
    /// fields are never added or changed. Fields the format refuses to update are removed so
    /// no stale creation date survives.
    static func synchronizeImageCreationDates(in url: URL, to date: Date) throws {
        try rewriteImageMetadata(at: url) { metadata, properties in
            let fields = ExifDateCodec.Field.all.filter { hasValue(for: $0, in: properties) }
            for field in fields {
                let offset = ExifDateCodec.offset(for: field, in: properties)
                let value = ExifDateCodec.xmpString(from: date, offset: offset)
                guard CGImageMetadataSetValueMatchingImageProperty(
                    metadata,
                    field.dictionary,
                    field.dateKey,
                    value as CFString
                ) else {
                    throw metadataWriteError
                }
            }
            return !fields.isEmpty
        }

        let staleFields = embeddedFields(at: url)
            .filter { abs($0.value.timeIntervalSince(date)) > FileDateRepairPlanner.timestampTolerance }
            .map(\.field)
        guard !staleFields.isEmpty else { return }

        try rewriteImageMetadata(at: url) { metadata, _ in
            for field in staleFields {
                guard let tag = CGImageMetadataCopyTagMatchingImageProperty(
                    metadata,
                    field.dictionary,
                    field.dateKey
                ), let prefix = CGImageMetadataTagCopyPrefix(tag),
                      let name = CGImageMetadataTagCopyName(tag) else {
                    continue
                }
                CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
            }
            return true
        }
    }

    /// Copies the image container to a temporary sibling with edited metadata, then atomically
    /// replaces the original. `edit` returns false when nothing needs to change.
    static func rewriteImageMetadata(
        at url: URL,
        edit: (CGMutableImageMetadata, [CFString: Any]) throws -> Bool
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey: "The image metadata could not be read."]
            )
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        guard try edit(metadata, properties) else { return }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".image-metadata-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
            throw metadataWriteError
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unsupported format"
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The image metadata could not be updated without re-encoding (\(reason))."
                ]
            )
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    private static var metadataWriteError: CocoaError {
        CocoaError(
            .fileWriteUnknown,
            userInfo: [NSLocalizedDescriptionKey: "The synchronized image metadata could not be saved."]
        )
    }

    private static func hasValue(for field: ExifDateCodec.Field, in properties: [CFString: Any]) -> Bool {
        (properties[field.dictionary] as? [CFString: Any])?[field.dateKey] != nil
    }

    private static func embeddedFields(at url: URL) -> [(field: ExifDateCodec.Field, value: Date)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }
        return ExifDateCodec.Field.all.compactMap { field in
            ExifDateCodec.date(for: field, in: properties).map { (field, $0) }
        }
    }

    /// Restores a previously captured filesystem date pair after an unsuccessful repair.
    static func restoreFileDates(created: Date, modified: Date, to url: URL) throws {
        try applyFileDates(to: url, created: created, modified: modified)
    }

    private static func readExifOriginalDate(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return ExifDateCodec.date(for: .original, in: properties)
            ?? ExifDateCodec.date(for: .tiff, in: properties)
    }

    /// Updates Finder's Date Created and Date Modified.
    static func applyFileDates(to url: URL, created: Date, modified: Date) throws {
        try setAPFSBirthAndModificationTimes(url: url, created: created, modified: modified)

        var resourceValues = URLResourceValues()
        resourceValues.creationDate = created
        resourceValues.contentModificationDate = modified
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)

        try FileManager.default.setAttributes(
            [
                .creationDate: created,
                .modificationDate: modified
            ],
            ofItemAtPath: url.path
        )
    }

    /// Sets APFS birth time (Finder "Date Created"). Must run after any file replace/move.
    private static func setAPFSBirthAndModificationTimes(
        url: URL,
        created: Date,
        modified: Date
    ) throws {
        var crtime = makeTimespec(from: created)
        var modtime = makeTimespec(from: modified)
        var attributeList = attrlist()
        attributeList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributeList.commonattr = attrgroup_t(UInt32(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME))

        try url.path.withCString { path in
            let status = withUnsafeMutablePointer(to: &attributeList) { listPointer in
                withUnsafeMutablePointer(to: &crtime) { createdPointer in
                    withUnsafeMutablePointer(to: &modtime) { modifiedPointer in
                        var buffer = (createdPointer.pointee, modifiedPointer.pointee)
                        return withUnsafeMutablePointer(to: &buffer) { bufferPointer in
                            setattrlist(
                                path,
                                UnsafeMutableRawPointer(listPointer).assumingMemoryBound(to: attrlist.self),
                                UnsafeMutableRawPointer(bufferPointer),
                                MemoryLayout<timespec>.size * 2,
                                0
                            )
                        }
                    }
                }
            }
            if status != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
        }
    }

    private static func setAPFSBirthTime(url: URL, created: Date) throws {
        var crtime = makeTimespec(from: created)
        var attributeList = attrlist()
        attributeList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributeList.commonattr = attrgroup_t(UInt32(ATTR_CMN_CRTIME))

        try url.path.withCString { path in
            let status = withUnsafeMutablePointer(to: &attributeList) { listPointer in
                withUnsafeMutablePointer(to: &crtime) { createdPointer in
                    setattrlist(
                        path,
                        UnsafeMutableRawPointer(listPointer).assumingMemoryBound(to: attrlist.self),
                        UnsafeMutableRawPointer(createdPointer),
                        MemoryLayout<timespec>.size,
                        0
                    )
                }
            }
            if status != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
        }
    }

    private static func makeTimespec(from date: Date) -> timespec {
        let seconds = date.timeIntervalSince1970
        var spec = timespec()
        spec.tv_sec = __darwin_time_t(seconds.rounded(.down))
        let fraction = seconds - Double(spec.tv_sec)
        spec.tv_nsec = Int((fraction * 1_000_000_000).rounded())
        return spec
    }
}
