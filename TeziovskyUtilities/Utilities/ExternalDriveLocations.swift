import Darwin
import Foundation

enum ExternalDriveFolderRole: String, Sendable {
    case source
    case destination

    /// Where the folder picker opens. Uses the real home directory: inside the sandbox
    /// `NSHomeDirectory()` points at the app container.
    var suggestedPath: String {
        switch self {
        case .source:
            return "\(Self.realHomeDirectory)/Pictures/_To_Homelab_Media"
        case .destination:
            return "/Volumes/MEDIA"
        }
    }

    private static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }

    fileprivate var bookmarkKey: String {
        switch self {
        case .source: return "externalDriveSourceBookmark"
        case .destination: return "externalDriveDestinationBookmark"
        }
    }

    fileprivate var pathKey: String {
        switch self {
        case .source: return "externalDriveSourcePath"
        case .destination: return "externalDriveDestinationPath"
        }
    }
}

enum ExternalDriveFolderResolution: Equatable {
    case notChosen
    /// A folder was chosen but its bookmark no longer resolves; carries the stored path.
    case unavailable(path: String)
    case resolved(URL)
}

extension AppSettings {
    /// Storage for the external-drive folders. Tests swap it for a throwaway suite.
    nonisolated(unsafe) static var externalDriveDefaults: UserDefaults = .standard

    static func storeExternalDriveFolder(_ url: URL, role: ExternalDriveFolderRole) {
        externalDriveDefaults.set(url.path, forKey: role.pathKey)
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            externalDriveDefaults.set(bookmark, forKey: role.bookmarkKey)
        } else {
            // Never leave the previous folder's bookmark behind: it would win over the new path.
            externalDriveDefaults.removeObject(forKey: role.bookmarkKey)
        }
    }

    /// Resolves the chosen folder from its security-scoped bookmark (re-storing a stale one).
    /// Callers start/stop security-scoped access themselves.
    static func resolveExternalDriveFolder(_ role: ExternalDriveFolderRole) -> ExternalDriveFolderResolution {
        let storedPath = externalDriveDefaults.string(forKey: role.pathKey)
        guard let data = externalDriveDefaults.data(forKey: role.bookmarkKey) else {
            guard let storedPath else { return .notChosen }
            return .unavailable(path: storedPath)
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            guard let storedPath else { return .notChosen }
            return .unavailable(path: storedPath)
        }
        if isStale || url.path != storedPath {
            let didAccess = url.startAccessingSecurityScopedResource()
            storeExternalDriveFolder(url, role: role)
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        return .resolved(url)
    }
}

enum ExternalDrivePreflight: Equatable {
    case ready(freeBytes: Int64)
    case notConnected(String)
    case notChosen
}

enum ExternalDriveLocations {
    static func preflight(
        destination: ExternalDriveFolderResolution,
        bootVolume: URL = URL(fileURLWithPath: "/")
    ) -> ExternalDrivePreflight {
        switch destination {
        case .notChosen:
            return .notChosen
        case let .unavailable(path):
            return .notConnected(notConnectedMessage(name: URL(fileURLWithPath: path).lastPathComponent))
        case let .resolved(url):
            let message = ExternalDrivePreflight.notConnected(notConnectedMessage(name: url.lastPathComponent))
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: [
                      .volumeIdentifierKey,
                      .volumeAvailableCapacityForImportantUsageKey,
                      .volumeAvailableCapacityKey
                  ]),
                  let volume = values.volumeIdentifier as? NSObject,
                  let bootValues = try? bootVolume.resourceValues(forKeys: [.volumeIdentifierKey]),
                  let boot = bootValues.volumeIdentifier as? NSObject,
                  volume != boot
            else { return message }
            return .ready(freeBytes: freeBytes(
                important: values.volumeAvailableCapacityForImportantUsage,
                plain: values.volumeAvailableCapacity.map(Int64.init)
            ))
        }
    }

    /// The larger of the two capacities: on the boot volume "important usage" includes
    /// purgeable space, while external volumes (exFAT) report it as 0 and only the plain
    /// capacity is meaningful.
    static func freeBytes(important: Int64?, plain: Int64?) -> Int64 {
        max(important ?? 0, plain ?? 0)
    }

    private static func notConnectedMessage(name: String) -> String {
        "\(name) isn't connected. Connect the drive and press Check Again (⌘R)."
    }
}

/// Plain-text log of drive moves, kept in the app's Library/Logs. Never throws.
struct ExternalDriveLog: Sendable {
    static let shared: ExternalDriveLog = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ExternalDriveLog(fileURL: library.appendingPathComponent("Logs/external-drive.log"))
    }()

    private static let queue = DispatchQueue(label: "ExternalDriveLog")

    let fileURL: URL

    /// Creates the (empty) log file if no run has written one yet, so "Show Log" has something to reveal.
    func ensureFileExists() {
        let url = fileURL
        Self.queue.sync {
            let manager = FileManager.default
            guard !manager.fileExists(atPath: url.path) else { return }
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
    }

    func append(_ line: String) {
        let url = fileURL
        Self.queue.sync {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let data = Data("\(formatter.string(from: Date()))  \(line)\n".utf8)
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
