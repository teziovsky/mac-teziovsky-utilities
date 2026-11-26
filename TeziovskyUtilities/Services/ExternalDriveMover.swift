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

/// How a finished partial copy gets its final name. Both never replace an existing file.
enum ExternalDriveRenameStrategy: Sendable {
    /// `renamex_np(RENAME_EXCL)`, falling back to `.reserveName` where the volume lacks it (exFAT).
    case exclusiveRename
    /// Claim the name with an exclusive create, then rename over that placeholder. Forced only by tests.
    case reserveName
}

/// Moves one unit (a file, or a Live Photo pair) to the archive drive: copy, prove each copy identical,
/// and only then trash the originals. A unit that doesn't fully verify leaves no copies behind.
struct ExternalDriveMover: Sendable {
    static let changedMessage = "Changed since the check. Check again (⌘R)."
    static let nothingToMoveMessage = "Nothing to move"
    static let defaultTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    static let defaultFlush: @Sendable ([URL], URL) throws -> Void = { files, destinationRoot in
        try ExternalDriveMoverFileSystem.flush(files, destinationRoot: destinationRoot)
    }
    static let defaultDeviceID: @Sendable (URL) -> dev_t? = { ExternalDriveMoverFileSystem.deviceID(of: $0) }

    private let copier: ExternalDriveCopying
    private let trash: @Sendable (URL) throws -> Void
    private let flush: @Sendable (_ files: [URL], _ destinationRoot: URL) throws -> Void
    private let deviceID: @Sendable (URL) -> dev_t?
    private let log: @Sendable (String) -> Void
    private let renameStrategy: ExternalDriveRenameStrategy

    init(copier: ExternalDriveCopying = CopyfileCopier(),
         trash: @escaping @Sendable (URL) throws -> Void = defaultTrash,
         flush: @escaping @Sendable (_ files: [URL], _ destinationRoot: URL) throws -> Void = defaultFlush,
         deviceID: @escaping @Sendable (URL) -> dev_t? = defaultDeviceID,
         log: @escaping @Sendable (String) -> Void = { _ in },
         renameStrategy: ExternalDriveRenameStrategy = .exclusiveRename) {
        self.copier = copier
        self.trash = trash
        self.flush = flush
        self.deviceID = deviceID
        self.log = log
        self.renameStrategy = renameStrategy
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

    /// The volume the drive folder is on now; a run pins it and passes it to every unit.
    func destinationDevice(_ destinationRoot: URL) -> dev_t? {
        deviceID(destinationRoot)
    }

    /// False when another volume now sits at the drive folder's path (the drive was swapped mid-run).
    private func isPinnedVolume(_ destinationRoot: URL, _ destinationDevice: dev_t?) -> Bool {
        guard let destinationDevice else { return true }
        return deviceID(destinationRoot) == destinationDevice
    }

    func move(_ unit: ExternalDriveUnit, sourceRoot: URL, destinationRoot: URL, destinationDevice: dev_t? = nil,
              checkedFingerprints: [String: FileMetadataFingerprint],
              progress: @Sendable (Int64) -> Bool) -> ExternalDriveUnitOutcome {
        guard !unit.relativePaths.isEmpty else { return .failed(Self.nothingToMoveMessage) }
        var members: [Member] = []
        for path in unit.relativePaths {
            guard let checked = checkedFingerprints[path],
                  let member = currentMember(path, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                  Self.sameAsChecked(member.fingerprint, checked) else {
                return .failed(Self.changedMessage)
            }
            members.append(member)
        }
        if let outcome = existingDestinationOutcome(members) { return outcome }

        let created = Created()
        do {
            guard isPinnedVolume(destinationRoot, destinationDevice) else {
                throw Stop(outcome: .destinationUnavailable)
            }
            try prepareFolders(for: members, destinationRoot: destinationRoot, created: created)
            var completed: Int64 = 0
            for member in members {
                try copyMember(member, completedBytes: completed, created: created, progress: progress)
                completed += Int64(member.fingerprint.size)
                guard progress(completed) else { throw Stop(outcome: .cancelled) }
                fixUpMetadata(of: member)
            }
            do {
                try flush(members.map(\.destination), destinationRoot)
            } catch {
                throw Stop(outcome: .failed(
                    "Couldn't flush the copy to \(destinationRoot.lastPathComponent): \(error.localizedDescription)"))
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

    /// `.alreadyOnDestination` when any member's destination exists (even a dangling symlink); nil when none do.
    private func existingDestinationOutcome(_ members: [Member]) -> ExternalDriveUnitOutcome? {
        for member in members {
            switch ExternalDriveMoverFileSystem.entryExists(member.destination) {
            case .success(true): return .alreadyOnDestination
            case .success(false): continue
            case .failure(let error):
                return .failed("Couldn't check \(member.relativePath) on the drive: \(error.localizedDescription)")
            }
        }
        return nil
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
        return FileMetadataFingerprint.differences(source: checked, destination: current, resolution: .microsecond)
            .isEmpty
    }

    /// Creates the missing folders below the root one level at a time; never creates the root itself,
    /// so an unmounted drive can't turn into a folder on the boot disk.
    private func prepareFolders(for members: [Member], destinationRoot: URL, created: Created) throws {
        guard ExternalDriveMoverFileSystem.isDirectory(destinationRoot) else {
            throw Stop(outcome: .destinationUnavailable)
        }
        for member in members {
            var folder = destinationRoot
            for component in member.relativePath.split(separator: "/").dropLast() {
                folder = folder.appendingPathComponent(String(component), isDirectory: true)
                switch ExternalDriveMoverFileSystem.makeFolderIfMissing(folder) {
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
        if let error = ExternalDriveMoverFileSystem.removeFile(partial) {
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

        // copyfile copies a Finder-"Locked" source's flag, which would block the rename and the fix-ups;
        // `fixUpMetadata` puts the source's flags back last.
        if let error = ExternalDriveMoverFileSystem.clearLockFlags(partial) {
            throw Stop(outcome: .failed(
                "Couldn't unlock the copy of \(member.relativePath): \(error.localizedDescription)"))
        }
        let renameError: POSIXError? = switch renameStrategy {
        case .exclusiveRename:
            ExternalDriveMoverFileSystem.renameWithoutReplacing(from: partial, to: member.destination)
        case .reserveName:
            ExternalDriveMoverFileSystem.renameReservingName(from: partial, to: member.destination)
        }
        if let error = renameError {
            if error.code == .EEXIST { throw Stop(outcome: .alreadyOnDestination) }
            throw Stop(outcome: .failed(
                "Couldn't finish copying \(member.relativePath): \(error.localizedDescription)"))
        }
        created.files.removeAll { $0 == partial }
        created.files.append(member.destination)
    }

    /// `copyfile` rewrites some xattrs (e.g. `com.apple.quarantine`), leaves the birth time slightly off and,
    /// on exFAT, drops `UF_HIDDEN`, so restore the source's exact bytes, timestamps and flags. Dates follow
    /// the xattrs (xattr writes can touch them); flags go last because a "Locked" flag set earlier would
    /// make the xattr and date writes fail.
    /// Anything that can't be restored is logged here and caught by verification.
    private func fixUpMetadata(of member: Member) {
        let path = member.relativePath
        do {
            let sourceXattrs = try FileMetadataFingerprint.xattrValues(of: member.source)
            let destinationXattrs = try FileMetadataFingerprint.xattrValues(of: member.destination)
            for (name, value) in sourceXattrs.sorted(by: { $0.key < $1.key }) where destinationXattrs[name] != value {
                if let error = ExternalDriveMoverFileSystem.setXattr(name, value, on: member.destination) {
                    log("\(path): couldn't restore xattr \(name): \(error.localizedDescription)")
                }
            }
            let provenance = FileMetadataFingerprint.provenanceXattr
            if destinationXattrs[provenance] != nil, sourceXattrs[provenance] == nil,
               let error = ExternalDriveMoverFileSystem.removeXattr(provenance, from: member.destination) {
                log("\(path): couldn't remove \(provenance) from the copy: \(error.localizedDescription)")
            }
        } catch {
            log("\(path): couldn't read xattrs: \(error.localizedDescription)")
        }
        if let error = ExternalDriveMoverFileSystem.setDates(created: member.fingerprint.creationNanoseconds,
                                                modified: member.fingerprint.modificationNanoseconds,
                                                on: member.destination) {
            log("\(path): couldn't restore dates: \(error.localizedDescription)")
        }
        if let error = ExternalDriveMoverFileSystem.copyFlags(member.fingerprint.flags, to: member.destination) {
            log("\(path): couldn't restore flags: \(error.localizedDescription)")
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
                source: source, destination: destination, resolution: resolution)
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
            if let error = ExternalDriveMoverFileSystem.removeFile(file) {
                log("Rollback: couldn't remove \(file.path): \(error.localizedDescription)")
            }
        }
        for folder in created.folders.reversed() where rmdir(folder.path) != 0 {
            log("Rollback: couldn't remove the folder \(folder.path): errno \(errno)")
        }
    }
}

// MARK: - Already on the destination

extension ExternalDriveMover {
    /// Trashes the originals of a unit whose files are already on the destination, but only when every
    /// destination file is identical to its original (and is a different file, not the original itself).
    /// A member whose original is already gone while its copy exists (a pair half-trashed by an earlier
    /// run) counts as done.
    func trashOriginalIfIdentical(_ unit: ExternalDriveUnit, sourceRoot: URL, destinationRoot: URL,
                                  destinationDevice: dev_t? = nil) -> ExternalDriveUnitOutcome {
        guard !unit.relativePaths.isEmpty else { return .failed(Self.nothingToMoveMessage) }
        guard isPinnedVolume(destinationRoot, destinationDevice) else { return .destinationUnavailable }
        var toTrash: [String] = []
        var firstDifference: String?
        for path in unit.relativePaths {
            let source = sourceRoot.appendingPathComponent(path)
            let destination = destinationRoot.appendingPathComponent(path)
            if case .success(false) = ExternalDriveMoverFileSystem.entryExists(source),
               case .success(true) = ExternalDriveMoverFileSystem.entryExists(destination) {
                log("\(path): the original is already gone; the copy on the drive stays.")
                continue
            }
            switch compare(path, source: source, destination: destination) {
            case .failure(let stop): return stop.outcome
            case .success(let difference):
                firstDifference = firstDifference ?? difference
                toTrash.append(path)
            }
        }
        if let firstDifference { return .differentFileOnDestination(firstDifference) }

        var failure: String?
        for path in toTrash {
            do {
                try trash(sourceRoot.appendingPathComponent(path))
            } catch {
                log("\(path): couldn't move the original to the Trash: \(error.localizedDescription)")
                failure = failure ?? error.localizedDescription
            }
        }
        if let failure { return .failed("The original couldn't be moved to the Trash: \(failure)") }
        return .trashedOriginal
    }

    /// The first difference between an original and its copy (nil when identical), or why they can't be compared.
    private func compare(_ path: String, source: URL, destination: URL)
        -> Result<String?, Stop> {
        do {
            if try ExternalDriveMoverFileSystem.isSameFile(source, destination) {
                return .failure(Stop(outcome: .failed("\(path) on the drive is the original itself, not a copy.")))
            }
            guard let resolution = FileMetadataFingerprint.timeResolution(
                forVolumeOf: destination.deletingLastPathComponent()) else {
                return .failure(Stop(outcome: .failed("Couldn't read the drive's file system")))
            }
            let differences = FileMetadataFingerprint.differences(
                source: try .read(source, includeContent: true),
                destination: try .read(destination, includeContent: true),
                resolution: resolution)
            for difference in differences {
                log("\(path): \(difference.field) differs: \(difference.before) → \(difference.after)")
            }
            return .success(differences.first.map { "\(path): \($0.field) differs: \($0.before) → \($0.after)" })
        } catch {
            return .failure(Stop(outcome: .failed(
                "Couldn't compare \(path) with the drive: \(error.localizedDescription)")))
        }
    }
}
