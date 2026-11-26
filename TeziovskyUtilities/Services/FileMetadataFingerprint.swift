import CryptoKit
import Darwin
import Foundation

/// One field that differs between a source file and its copy.
struct MetadataDifference: Equatable, Sendable {
    let field: String
    let before: String
    let after: String
}

/// Timestamp granularity a volume can store, per field: exFAT keeps a set Created date only to the second
/// but Modified to 10 ms.
struct TimestampResolution: Equatable, Sendable {
    let creation: TimeInterval
    let modification: TimeInterval

    static let microsecond = TimestampResolution(creation: 0.000_001, modification: 0.000_001)
}

/// Everything a copy must preserve for it to count as identical: size, Finder dates, BSD flags,
/// extended attributes (by SHA-256) and, optionally, the content (by SHA-256).
struct FileMetadataFingerprint: Equatable, Sendable {
    let size: UInt64
    /// Nanoseconds since 1970, kept as integers so bucketing at a volume's resolution is exact.
    let creationNanoseconds: Int64
    let modificationNanoseconds: Int64
    let flags: UInt32
    let xattrDigests: [String: Data]
    let contentDigest: Data?

    /// Added by macOS on its own; a destination-only copy of it is not a difference.
    static let provenanceXattr = "com.apple.provenance"

    var creationDate: Date { Self.date(nanoseconds: creationNanoseconds) }
    var modificationDate: Date { Self.date(nanoseconds: modificationNanoseconds) }

    private static let chunkSize = 4 * 1024 * 1024

    // MARK: Reading

    static func read(_ url: URL, includeContent: Bool) throws -> FileMetadataFingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(currentErrno()) }
        // A symlink would make size/flags describe the link while content describes its target.
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return FileMetadataFingerprint(
            size: UInt64(info.st_size),
            creationNanoseconds: nanoseconds(info.st_birthtimespec),
            modificationNanoseconds: nanoseconds(info.st_mtimespec),
            flags: info.st_flags,
            xattrDigests: try xattrDigests(of: url),
            contentDigest: includeContent ? try contentDigest(of: url) : nil
        )
    }

    private static func currentErrno() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }

    private static func nanoseconds(_ spec: timespec) -> Int64 {
        Int64(spec.tv_sec) * 1_000_000_000 + Int64(spec.tv_nsec)
    }

    private static func date(nanoseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000)
    }

    private static func xattrDigests(of url: URL) throws -> [String: Data] {
        try xattrValues(of: url).mapValues { Data(SHA256.hash(data: $0)) }
    }

    /// Every extended attribute of `url` (not following symlinks), with its exact bytes.
    static func xattrValues(of url: URL) throws -> [String: Data] {
        let path = url.path
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
            let names = buffer[0..<read].split(separator: 0).map { name in
                String(cString: Array(name) + [0])
            }
            var values: [String: Data] = [:]
            for name in names {
                values[name] = try xattrValue(named: name, at: path)
            }
            return values
        }
        throw POSIXError(.EAGAIN)
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
        resolution: TimestampResolution,
        ignoredDestinationOnlyXattrs: Set<String> = [provenanceXattr]
    ) -> [MetadataDifference] {
        var result: [MetadataDifference] = []

        if source.size != destination.size {
            result.append(MetadataDifference(field: "size", before: "\(source.size)", after: "\(destination.size)"))
        }
        if !sameInstant(source.creationNanoseconds, destination.creationNanoseconds, resolution: resolution.creation) {
            result.append(MetadataDifference(
                field: "created", before: describe(source.creationDate), after: describe(destination.creationDate)))
        }
        if !sameInstant(source.modificationNanoseconds, destination.modificationNanoseconds,
                        resolution: resolution.modification) {
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

        // A digest on only one side is a difference too: nothing proves the contents match.
        if source.contentDigest != destination.contentDigest {
            result.append(MetadataDifference(
                field: "content", before: describe(source.contentDigest), after: describe(destination.contentDigest)))
        }
        return result
    }

    private static func sameInstant(_ lhs: Int64, _ rhs: Int64, resolution: TimeInterval) -> Bool {
        let bucket = Int64((resolution * 1_000_000_000).rounded())
        guard bucket > 1 else { return lhs == rhs }
        return floorDivide(lhs, bucket) == floorDivide(rhs, bucket)
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    private static func describe(_ digest: Data?) -> String {
        guard let digest else { return "missing" }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ date: Date) -> String {
        let total = date.timeIntervalSince1970
        let whole = total.rounded(.down)
        let micros = Int(((total - whole) * 1_000_000).rounded(.down))
        let seconds = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: whole))
        return seconds.replacingOccurrences(of: "Z", with: String(format: ".%06dZ", micros))
    }

    private static func hex(_ flags: UInt32) -> String {
        "0x" + String(flags, radix: 16)
    }

    // MARK: Volume time resolution

    /// Timestamp granularity the volume holding `url` can store; nil when it cannot be determined.
    static func timeResolution(forVolumeOf url: URL) -> TimestampResolution? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let type = withUnsafePointer(to: &info.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return timeResolution(forFileSystemType: type)
    }

    /// HFS+ stores whole seconds; anything unknown is treated as the coarsest 1 s.
    static func timeResolution(forFileSystemType type: String) -> TimestampResolution {
        switch type {
        case "exfat": return TimestampResolution(creation: 1, modification: 0.01)
        case "apfs": return .microsecond
        default: return TimestampResolution(creation: 1, modification: 1)
        }
    }
}
