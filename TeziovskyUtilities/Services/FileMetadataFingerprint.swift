import CryptoKit
import Darwin
import Foundation

/// One field that differs between a source file and its copy.
struct MetadataDifference: Equatable, Sendable {
    let field: String
    let before: String
    let after: String
}

/// Everything a copy must preserve for it to count as identical: size, Finder dates, BSD flags,
/// extended attributes (by SHA-256) and, optionally, the content (by SHA-256).
struct FileMetadataFingerprint: Equatable, Sendable {
    let size: UInt64
    let creationDate: Date
    let modificationDate: Date
    let flags: UInt32
    let xattrDigests: [String: Data]
    let contentDigest: Data?

    /// Added by macOS on its own; a destination-only copy of it is not a difference.
    static let provenanceXattr = "com.apple.provenance"

    private static let chunkSize = 4 * 1024 * 1024

    // MARK: Reading

    static func read(_ url: URL, includeContent: Bool) throws -> FileMetadataFingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(currentErrno()) }
        return FileMetadataFingerprint(
            size: UInt64(info.st_size),
            creationDate: date(info.st_birthtimespec),
            modificationDate: date(info.st_mtimespec),
            flags: info.st_flags,
            xattrDigests: try xattrDigests(of: url),
            contentDigest: includeContent ? try contentDigest(of: url) : nil
        )
    }

    private static func currentErrno() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }

    private static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    private static func xattrDigests(of url: URL) throws -> [String: Data] {
        let path = url.path
        var names: [String] = []
        // The list can change between the size query and the read; retry on ERANGE.
        for _ in 0..<5 {
            let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { throw POSIXError(currentErrno()) }
            if length == 0 { return [:] }
            var buffer = [CChar](repeating: 0, count: length)
            let read = listxattr(path, &buffer, length, XATTR_NOFOLLOW)
            if read < 0 {
                if errno == ERANGE { continue }
                throw POSIXError(currentErrno())
            }
            names = buffer[0..<read].split(separator: 0).map { name in
                String(cString: Array(name) + [0])
            }
            break
        }

        var digests: [String: Data] = [:]
        for name in names {
            digests[name] = Data(SHA256.hash(data: try xattrValue(named: name, at: path)))
        }
        return digests
    }

    private static func xattrValue(named name: String, at path: String) throws -> Data {
        for _ in 0..<5 {
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { throw POSIXError(currentErrno()) }
            if length == 0 { return Data() }
            var buffer = [UInt8](repeating: 0, count: length)
            let read = getxattr(path, name, &buffer, length, 0, XATTR_NOFOLLOW)
            if read < 0 {
                if errno == ERANGE { continue }
                throw POSIXError(currentErrno())
            }
            return Data(buffer[0..<read])
        }
        throw POSIXError(.EAGAIN)
    }

    private static func contentDigest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    // MARK: Comparing

    static func differences(
        source: FileMetadataFingerprint,
        destination: FileMetadataFingerprint,
        timeResolution: TimeInterval,
        ignoredDestinationOnlyXattrs: Set<String> = [provenanceXattr]
    ) -> [MetadataDifference] {
        var result: [MetadataDifference] = []

        if source.size != destination.size {
            result.append(MetadataDifference(field: "size", before: "\(source.size)", after: "\(destination.size)"))
        }
        if !sameInstant(source.creationDate, destination.creationDate, resolution: timeResolution) {
            result.append(MetadataDifference(
                field: "created", before: describe(source.creationDate), after: describe(destination.creationDate)))
        }
        if !sameInstant(source.modificationDate, destination.modificationDate, resolution: timeResolution) {
            result.append(MetadataDifference(
                field: "modified", before: describe(source.modificationDate),
                after: describe(destination.modificationDate)))
        }
        let compressed = UInt32(UF_COMPRESSED)
        if source.flags & ~compressed != destination.flags & ~compressed {
            result.append(MetadataDifference(
                field: "flags", before: hex(source.flags), after: hex(destination.flags)))
        }

        for name in source.xattrDigests.keys.sorted() {
            let before = source.xattrDigests[name]
            let after = destination.xattrDigests[name]
            if before != after {
                result.append(MetadataDifference(
                    field: "xattr \(name)", before: describe(before), after: describe(after)))
            }
        }
        for name in destination.xattrDigests.keys.sorted()
        where source.xattrDigests[name] == nil && !ignoredDestinationOnlyXattrs.contains(name) {
            result.append(MetadataDifference(
                field: "xattr \(name)", before: "missing", after: describe(destination.xattrDigests[name])))
        }

        if let before = source.contentDigest, let after = destination.contentDigest, before != after {
            result.append(MetadataDifference(field: "content", before: describe(before), after: describe(after)))
        }
        return result
    }

    private static func sameInstant(_ lhs: Date, _ rhs: Date, resolution: TimeInterval) -> Bool {
        guard resolution > 0 else { return lhs == rhs }
        let left = (lhs.timeIntervalSince1970 / resolution).rounded(.down)
        let right = (rhs.timeIntervalSince1970 / resolution).rounded(.down)
        return left == right
    }

    private static func describe(_ digest: Data?) -> String {
        guard let digest else { return "missing" }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ date: Date) -> String {
        let whole = date.timeIntervalSince1970.rounded(.down)
        let micros = Int(((date.timeIntervalSince1970 - whole) * 1_000_000).rounded(.down))
        let seconds = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: whole))
        return seconds.replacingOccurrences(of: "Z", with: String(format: ".%06dZ", micros))
    }

    private static func hex(_ flags: UInt32) -> String {
        "0x" + String(flags, radix: 16)
    }

    // MARK: Volume time resolution

    /// Timestamp granularity the volume holding `url` can store.
    static func timeResolution(forVolumeOf url: URL) -> TimeInterval {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return 1 }
        let type = withUnsafePointer(to: &info.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        switch type {
        case "exfat": return 0.01
        case "apfs", "hfs": return 0.000_001
        default: return 1
        }
    }
}
