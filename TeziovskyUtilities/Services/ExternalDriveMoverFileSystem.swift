import Darwin
import Foundation

/// Thin POSIX wrappers that never follow symlinks.
enum ExternalDriveMoverFileSystem {
    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// True for anything at `url`, including a dangling symlink.
    static func entryExists(_ url: URL) -> Result<Bool, POSIXError> {
        var info = stat()
        if lstat(url.path, &info) == 0 { return .success(true) }
        return errno == ENOENT ? .success(false) : .failure(lastError())
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// `true` when this call created the folder; an existing non-folder is an error.
    static func makeFolderIfMissing(_ url: URL) -> Result<Bool, POSIXError> {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return info.st_mode & S_IFMT == S_IFDIR ? .success(false) : .failure(POSIXError(.ENOTDIR))
        }
        guard errno == ENOENT else { return .failure(lastError()) }
        if mkdir(url.path, 0o777) == 0 { return .success(true) }
        if errno == EEXIST, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return .success(false) }
        return .failure(lastError())
    }

    /// Unlinks a file or symlink (never a folder); a missing entry is fine. A verified copy carries the
    /// source's "Locked" flag, so for a non-folder clear the flags and retry once if unlink isn't permitted.
    static func removeFile(_ url: URL) -> POSIXError? {
        if unlink(url.path) == 0 || errno == ENOENT { return nil }
        guard errno == EPERM else { return lastError() }
        let error = lastError()
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { return error }
        if lchflags(url.path, 0) == 0, unlink(url.path) == 0 { return nil }
        return lastError()
    }

    private static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    /// Clears the immutable/append-only flags so the copy can be renamed and fixed up.
    static func clearLockFlags(_ url: URL) -> POSIXError? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return lastError() }
        guard info.st_flags & lockFlags != 0 else { return nil }
        return lchflags(url.path, info.st_flags & ~lockFlags) == 0 ? nil : lastError()
    }

    /// Renames `source` to `destination`, failing with EEXIST rather than replacing anything there.
    static func renameWithoutReplacing(from source: URL, to destination: URL) -> POSIXError? {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return nil }
        guard errno == ENOTSUP || errno == EOPNOTSUPP else { return lastError() }
        return renameReservingName(from: source, to: destination)
    }

    /// For volumes without RENAME_EXCL (exFAT via FSKit): claim the name with an exclusive create, which
    /// fails if anything (even a dangling symlink) is there, then let the copy replace that empty placeholder.
    /// Before replacing or cleaning up the placeholder, check it is still the same inode, so nothing that
    /// appeared there meanwhile is ever replaced or removed.
    static func renameReservingName(from source: URL, to destination: URL) -> POSIXError? {
        let placeholder = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard placeholder >= 0 else { return lastError() }
        var created = stat()
        let statResult = fstat(placeholder, &created)
        close(placeholder)
        guard statResult == 0 else { return lastError() }
        func isPlaceholder() -> Bool {
            var info = stat()
            return lstat(destination.path, &info) == 0 && info.st_dev == created.st_dev && info.st_ino == created.st_ino
        }
        guard isPlaceholder() else { return POSIXError(.EEXIST) }
        if rename(source.path, destination.path) == 0 { return nil }
        let error = lastError()
        if isPlaceholder() { unlink(destination.path) }
        return error
    }

    /// Gives `url` the source's flags, keeping its own `UF_COMPRESSED` (a storage detail, not metadata).
    static func copyFlags(_ sourceFlags: UInt32, to url: URL) -> POSIXError? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return lastError() }
        let compressed = UInt32(UF_COMPRESSED)
        let wanted = (sourceFlags & ~compressed) | (info.st_flags & compressed)
        if wanted == info.st_flags { return nil }
        return lchflags(url.path, wanted) == 0 ? nil : lastError()
    }

    static func setXattr(_ name: String, _ value: Data, on url: URL) -> POSIXError? {
        let result = value.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        return result == 0 ? nil : lastError()
    }

    static func removeXattr(_ name: String, from url: URL) -> POSIXError? {
        removexattr(url.path, name, XATTR_NOFOLLOW) == 0 ? nil : lastError()
    }

    /// Sets the exact birth and modification times in one call, so the kernel can't pull one toward the other.
    static func setDates(created: Int64, modified: Int64, on url: URL) -> POSIXError? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        var buffer = (timespec(nanoseconds: created), timespec(nanoseconds: modified))
        let result = setattrlist(url.path, &list, &buffer, MemoryLayout<timespec>.size * 2, UInt32(FSOPT_NOFOLLOW))
        return result == 0 ? nil : lastError()
    }

    /// Pushes finished copies all the way to the drive before any original is trashed: each file and its
    /// folder get `F_FULLFSYNC` (plain `fsync` where unsupported), then the whole volume is synced, because
    /// exFAT keeps xattrs in separate `._` AppleDouble files.
    static func flush(_ files: [URL], destinationRoot: URL) throws {
        var folders: [URL] = []
        for file in files {
            try fullSync(file, flags: O_RDONLY | O_NOFOLLOW)
            let folder = file.deletingLastPathComponent()
            if !folders.contains(folder) { folders.append(folder) }
        }
        for folder in folders { try fullSync(folder, flags: O_RDONLY | O_DIRECTORY) }
        let result = sync_volume_np(destinationRoot.path, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result > 0 ? result : errno) ?? .EIO) }
    }

    private static func fullSync(_ url: URL, flags: Int32) throws {
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else { throw lastError() }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard errno == ENOTSUP || errno == EOPNOTSUPP else { throw lastError() }
        if fsync(descriptor) != 0 { throw lastError() }
    }

    static func isSameFile(_ lhs: URL, _ rhs: URL) throws -> Bool {
        var left = stat()
        var right = stat()
        guard lstat(lhs.path, &left) == 0, lstat(rhs.path, &right) == 0 else { throw lastError() }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }
}

private extension timespec {
    /// Floor division keeps `tv_nsec` in 0..<1e9 for dates before 1970.
    init(nanoseconds: Int64) {
        var seconds = nanoseconds / 1_000_000_000
        var remainder = nanoseconds % 1_000_000_000
        if remainder < 0 {
            remainder += 1_000_000_000
            seconds -= 1
        }
        self.init(tv_sec: Int(seconds), tv_nsec: Int(remainder))
    }
}
