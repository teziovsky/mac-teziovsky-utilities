import Darwin
import Foundation

/// Copies one file. `progress` gets the bytes copied so far for this file and returns `false` to stop,
/// in which case the copy throws `CancellationError`. Never overwrites an existing destination.
protocol ExternalDriveCopying: Sendable {
    func copy(from source: URL, to destination: URL, progress: (Int64) -> Bool) throws
}

/// `copyfile(COPYFILE_ALL | COPYFILE_EXCL)` with a progress callback.
struct CopyfileCopier: ExternalDriveCopying {
    private final class Context {
        let progress: (Int64) -> Bool
        var stopped = false
        init(progress: @escaping (Int64) -> Bool) { self.progress = progress }
    }

    func copy(from source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try withoutActuallyEscaping(progress) { progress in
            let context = Context(progress: progress)
            guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
            defer { copyfile_state_free(state) }

            let callback: copyfile_callback_t = { what, stage, state, _, _, info in
                guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state, let info else {
                    return COPYFILE_CONTINUE
                }
                let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                if context.progress(Int64(copied)) { return COPYFILE_CONTINUE }
                context.stopped = true
                return COPYFILE_QUIT
            }
            let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer)
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
            let result = withExtendedLifetime(context) {
                Darwin.copyfile(source.path, destination.path, state, flags)
            }
            if context.stopped { throw CancellationError() }
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}

enum ExternalDriveUnitOutcome: Sendable, Equatable {
    case moved
    case alreadyOnDestination
    case cancelled
    case failed(String)
    case verifiedButNotTrashed(String)
    case trashedOriginal
    case differentFileOnDestination(String)
    case destinationUnavailable
}

/// Moves one unit (a file, or a Live Photo pair) to the archive drive: copy, prove each copy identical,
/// and only then trash the originals. A unit that doesn't fully verify leaves no copies behind.
struct ExternalDriveMover: Sendable {
    static let changedMessage = "Changed since the check. Check again (⌘R)."
    static let defaultTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private let copier: ExternalDriveCopying
    private let trash: @Sendable (URL) throws -> Void
    private let log: @Sendable (String) -> Void

    init(copier: ExternalDriveCopying = CopyfileCopier(),
         trash: @escaping @Sendable (URL) throws -> Void = defaultTrash,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.copier = copier
        self.trash = trash
        self.log = log
    }

    private struct Member {
        let relativePath: String
        let source: URL
        let destination: URL
        /// The source as re-read just before copying (no content digest); exact timestamps come from here.
        let fingerprint: FileMetadataFingerprint

        var partial: URL {
            destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial")
        }
    }

    /// Paths this call created, so a rollback never touches anything else.
    private final class Created {
        var files: [URL] = []
        var folders: [URL] = []
    }

    /// Ends the unit early with `outcome`, after a rollback.
    private struct Stop: Error {
        let outcome: ExternalDriveUnitOutcome
    }

    // MARK: Move

    func move(_ unit: ExternalDriveUnit, sourceRoot: URL, destinationRoot: URL,
              checkedFingerprints: [String: FileMetadataFingerprint],
              progress: @Sendable (Int64) -> Bool) -> ExternalDriveUnitOutcome {
        var members: [Member] = []
        for path in unit.relativePaths {
            guard let checked = checkedFingerprints[path],
                  let member = currentMember(path, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                  Self.sameAsChecked(member.fingerprint, checked) else {
                return .failed(Self.changedMessage)
            }
            members.append(member)
        }
        for member in members {
            switch MoverFileSystem.entryExists(member.destination) {
            case .success(true): return .alreadyOnDestination
            case .success(false): continue
            case .failure(let error):
                return .failed("Couldn't check \(member.relativePath) on the drive: \(error.localizedDescription)")
            }
        }

        let created = Created()
        do {
            try prepareFolders(for: members, destinationRoot: destinationRoot, created: created)
            var completed: Int64 = 0
            for member in members {
                try copyMember(member, completedBytes: completed, created: created, progress: progress)
                completed += Int64(member.fingerprint.size)
                guard progress(completed) else { throw Stop(outcome: .cancelled) }
                fixUpMetadata(of: member)
            }
            try verify(members, checkedFingerprints: checkedFingerprints, completedBytes: completed, progress: progress)
        } catch let stop as Stop {
            rollBack(created)
            return stop.outcome
        } catch {
            rollBack(created)
            return .failed(error.localizedDescription)
        }
        return trashSources(of: members)
    }

    private func currentMember(_ path: String, sourceRoot: URL, destinationRoot: URL) -> Member? {
        let source = sourceRoot.appendingPathComponent(path)
        guard let fingerprint = try? FileMetadataFingerprint.read(source, includeContent: false) else { return nil }
        return Member(relativePath: path, source: source,
                      destination: destinationRoot.appendingPathComponent(path), fingerprint: fingerprint)
    }

    private static func sameAsChecked(_ current: FileMetadataFingerprint, _ checked: FileMetadataFingerprint) -> Bool {
        let current = FileMetadataFingerprint(
            size: current.size, creationNanoseconds: current.creationNanoseconds,
            modificationNanoseconds: current.modificationNanoseconds, flags: current.flags,
            xattrDigests: current.xattrDigests, contentDigest: nil)
        let checked = FileMetadataFingerprint(
            size: checked.size, creationNanoseconds: checked.creationNanoseconds,
            modificationNanoseconds: checked.modificationNanoseconds, flags: checked.flags,
            xattrDigests: checked.xattrDigests, contentDigest: nil)
        return FileMetadataFingerprint.differences(source: checked, destination: current, timeResolution: 0.000_001)
            .isEmpty
    }

    /// Creates the missing folders below the root one level at a time; never creates the root itself,
    /// so an unmounted drive can't turn into a folder on the boot disk.
    private func prepareFolders(for members: [Member], destinationRoot: URL, created: Created) throws {
        guard MoverFileSystem.isDirectory(destinationRoot) else { throw Stop(outcome: .destinationUnavailable) }
        for member in members {
            var folder = destinationRoot
            for component in member.relativePath.split(separator: "/").dropLast() {
                folder = folder.appendingPathComponent(String(component), isDirectory: true)
                switch MoverFileSystem.makeFolderIfMissing(folder) {
                case .success(true): created.folders.append(folder)
                case .success(false): continue
                case .failure(let error):
                    throw Stop(outcome: .failed(
                        "Couldn't create the folder \(folder.lastPathComponent): \(error.localizedDescription)"))
                }
            }
        }
    }

    private func copyMember(_ member: Member, completedBytes: Int64, created: Created,
                            progress: @Sendable (Int64) -> Bool) throws {
        let partial = member.partial
        if let error = MoverFileSystem.removeFile(partial) {
            throw Stop(outcome: .failed(
                "Couldn't remove an old partial copy of \(member.relativePath): \(error.localizedDescription)"))
        }
        created.files.append(partial)

        var cancelRequested = false
        do {
            try copier.copy(from: member.source, to: partial) { bytes in
                let keepGoing = progress(completedBytes + bytes)
                if !keepGoing { cancelRequested = true }
                return keepGoing
            }
        } catch {
            if cancelRequested || error is CancellationError { throw Stop(outcome: .cancelled) }
            throw Stop(outcome: .failed("Couldn't copy \(member.relativePath): \(error.localizedDescription)"))
        }
        if cancelRequested { throw Stop(outcome: .cancelled) }

        guard renamex_np(partial.path, member.destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw Stop(outcome: .alreadyOnDestination) }
            let error = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            throw Stop(outcome: .failed(
                "Couldn't finish copying \(member.relativePath): \(error.localizedDescription)"))
        }
        created.files.removeAll { $0 == partial }
        created.files.append(member.destination)
    }

    /// `copyfile` rewrites some xattrs (e.g. `com.apple.quarantine`) and leaves the birth time slightly off,
    /// so restore the source's exact bytes and timestamps. Dates go last: xattr writes can touch them.
    /// Anything that can't be restored is logged here and caught by verification.
    private func fixUpMetadata(of member: Member) {
        let path = member.relativePath
        do {
            let sourceXattrs = try FileMetadataFingerprint.xattrValues(of: member.source)
            let destinationXattrs = try FileMetadataFingerprint.xattrValues(of: member.destination)
            for (name, value) in sourceXattrs.sorted(by: { $0.key < $1.key }) where destinationXattrs[name] != value {
                if let error = MoverFileSystem.setXattr(name, value, on: member.destination) {
                    log("\(path): couldn't restore xattr \(name): \(error.localizedDescription)")
                }
            }
            let provenance = FileMetadataFingerprint.provenanceXattr
            if destinationXattrs[provenance] != nil, sourceXattrs[provenance] == nil,
               let error = MoverFileSystem.removeXattr(provenance, from: member.destination) {
                log("\(path): couldn't remove \(provenance) from the copy: \(error.localizedDescription)")
            }
        } catch {
            log("\(path): couldn't read xattrs: \(error.localizedDescription)")
        }
        if let error = MoverFileSystem.setDates(created: member.fingerprint.creationNanoseconds,
                                                modified: member.fingerprint.modificationNanoseconds,
                                                on: member.destination) {
            log("\(path): couldn't restore dates: \(error.localizedDescription)")
        }
    }

    private func verify(_ members: [Member], checkedFingerprints: [String: FileMetadataFingerprint],
                        completedBytes: Int64, progress: @Sendable (Int64) -> Bool) throws {
        var firstDifference: MetadataDifference?
        for member in members {
            guard progress(completedBytes) else { throw Stop(outcome: .cancelled) }
            let folder = member.destination.deletingLastPathComponent()
            guard let resolution = FileMetadataFingerprint.timeResolution(forVolumeOf: folder) else {
                throw Stop(outcome: .failed("Couldn't read the drive's file system"))
            }
            let source: FileMetadataFingerprint
            let destination: FileMetadataFingerprint
            do {
                source = try .read(member.source, includeContent: true)
                destination = try .read(member.destination, includeContent: true)
            } catch {
                throw Stop(outcome: .failed("Couldn't verify \(member.relativePath): \(error.localizedDescription)"))
            }
            // What was verified must still be what the owner reviewed.
            guard let checked = checkedFingerprints[member.relativePath], Self.sameAsChecked(source, checked) else {
                throw Stop(outcome: .failed(Self.changedMessage))
            }
            let differences = FileMetadataFingerprint.differences(
                source: source, destination: destination, timeResolution: resolution)
            for difference in differences {
                log("\(member.relativePath): \(difference.field) differs: \(difference.before) → \(difference.after)")
            }
            firstDifference = firstDifference ?? differences.first
        }
        if let difference = firstDifference {
            throw Stop(outcome: .failed(
                "Copied, but \(difference.field) differs: \(difference.before) → \(difference.after)"))
        }
    }

    private func trashSources(of members: [Member]) -> ExternalDriveUnitOutcome {
        var failure: String?
        for member in members {
            do {
                try trash(member.source)
            } catch {
                log("\(member.relativePath): couldn't move the original to the Trash: \(error.localizedDescription)")
                failure = failure ?? error.localizedDescription
            }
        }
        guard let failure else { return .moved }
        return .verifiedButNotTrashed(
            "Copied and verified, but the original couldn't be moved to the Trash: \(failure)")
    }

    private func rollBack(_ created: Created) {
        for file in created.files.reversed() {
            if let error = MoverFileSystem.removeFile(file) {
                log("Rollback: couldn't remove \(file.path): \(error.localizedDescription)")
            }
        }
        for folder in created.folders.reversed() where rmdir(folder.path) != 0 {
            log("Rollback: couldn't remove the folder \(folder.path): errno \(errno)")
        }
    }

    // MARK: Already on the destination

    /// Trashes the originals of a unit whose files are already on the destination, but only when every
    /// destination file is identical to its original (and is a different file, not the original itself).
    func trashOriginalIfIdentical(_ unit: ExternalDriveUnit, sourceRoot: URL, destinationRoot: URL)
        -> ExternalDriveUnitOutcome {
        var firstDifference: String?
        for path in unit.relativePaths {
            let source = sourceRoot.appendingPathComponent(path)
            let destination = destinationRoot.appendingPathComponent(path)
            do {
                if try MoverFileSystem.isSameFile(source, destination) {
                    return .failed("\(path) on the drive is the original itself, not a copy.")
                }
                guard let resolution = FileMetadataFingerprint.timeResolution(
                    forVolumeOf: destination.deletingLastPathComponent()) else {
                    return .failed("Couldn't read the drive's file system")
                }
                let differences = FileMetadataFingerprint.differences(
                    source: try .read(source, includeContent: true),
                    destination: try .read(destination, includeContent: true),
                    timeResolution: resolution)
                for difference in differences {
                    log("\(path): \(difference.field) differs: \(difference.before) → \(difference.after)")
                }
                if firstDifference == nil, let difference = differences.first {
                    firstDifference = "\(path): \(difference.field) differs: \(difference.before) → \(difference.after)"
                }
            } catch {
                return .failed("Couldn't compare \(path) with the drive: \(error.localizedDescription)")
            }
        }
        if let firstDifference { return .differentFileOnDestination(firstDifference) }

        for path in unit.relativePaths {
            do {
                try trash(sourceRoot.appendingPathComponent(path))
            } catch {
                log("\(path): couldn't move the original to the Trash: \(error.localizedDescription)")
                return .failed("The original couldn't be moved to the Trash: \(error.localizedDescription)")
            }
        }
        return .trashedOriginal
    }
}

/// Thin POSIX wrappers that never follow symlinks.
private enum MoverFileSystem {
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

    /// Unlinks a file or symlink (never a folder); a missing entry is fine. A copy can carry the source's
    /// "Locked" flag, so clear flags and retry once if the first attempt isn't permitted.
    static func removeFile(_ url: URL) -> POSIXError? {
        if unlink(url.path) == 0 || errno == ENOENT { return nil }
        if errno == EPERM, lchflags(url.path, 0) == 0, unlink(url.path) == 0 { return nil }
        return lastError()
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
