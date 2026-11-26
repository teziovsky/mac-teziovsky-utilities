import Darwin
import Foundation

extension LocalMediaOrganizationItem {
    fileprivate func moved(to destination: URL, root: URL) -> LocalMediaOrganizationItem {
        LocalMediaOrganizationItem(
            sourceURL: sourceURL,
            sourceRelativePath: sourceRelativePath,
            destinationURL: destination,
            destinationRelativePath: LocalMediaOrganizationPlanner.relativePath(for: destination, root: root),
            proposedDate: proposedDate,
            proposedSource: proposedSource,
            isVideo: isVideo,
            destinationWasRenamed: destination.lastPathComponent != destinationURL.lastPathComponent,
            rootDirectory: rootDirectory,
            groupsWithPhotos: groupsWithPhotos
        )
    }
}

enum LocalMediaOrganizationPlan: Sendable, Equatable {
    case move(LocalMediaOrganizationItem)
    /// Already in its computed destination, or no usable date.
    case unchanged
    /// Stays in its year folder: it has no embedded date, and only file-system dates disagree
    /// with the folder's year.
    case kept(LocalMediaKeptItem)
    /// Belongs in a sibling year folder outside the scanned folder.
    case outsideScannedFolder(year: String)
}

/// A file trusted to its year folder: only file-system dates disagree, so nothing moves.
struct LocalMediaKeptItem: Identifiable, Sendable, Equatable {
    var id: String { relativePath }
    let fileURL: URL
    let relativePath: String
    let yearFolder: String
    let disagreeingDate: Date
    let disagreeingSource: FileDateSource
}

enum LocalMediaOrganizationPlanner {
    static let videoDirectoryName = "_Filmy"

    static func makeCandidate(
        fileURL: URL,
        relativePath: String,
        rootDirectory: URL,
        evidence: [FileDateEvidence],
        isVideo: Bool,
        groupsWithPhotos: Bool = false,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> LocalMediaOrganizationItem? {
        let outcome = plan(
            fileURL: fileURL,
            relativePath: relativePath,
            rootDirectory: rootDirectory,
            evidence: evidence,
            isVideo: isVideo,
            groupsWithPhotos: groupsWithPhotos,
            now: now,
            timeZone: timeZone
        )
        if case .move(let item) = outcome { return item }
        return nil
    }

    static func plan(
        fileURL: URL,
        relativePath: String,
        rootDirectory: URL,
        evidence: [FileDateEvidence],
        isVideo: Bool,
        groupsWithPhotos: Bool = false,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> LocalMediaOrganizationPlan {
        guard let placement = placement(
            in: fileURL.deletingLastPathComponent(),
            evidence: evidence,
            now: now,
            timeZone: timeZone
        ) else {
            return .unchanged
        }
        let stays: LocalMediaOrganizationPlan = placement.kept.map { kept in
            .kept(LocalMediaKeptItem(
                fileURL: fileURL,
                relativePath: relativePath,
                yearFolder: placement.year,
                disagreeingDate: kept.date,
                disagreeingSource: kept.source
            ))
        } ?? .unchanged

        // Live Photo motion files follow their still into the photo folder, not `_Filmy`.
        guard let destinationDirectory = destinationDirectory(
            for: fileURL.deletingLastPathComponent(),
            year: placement.year,
            placesAsVideo: isVideo && !groupsWithPhotos
        ) else {
            return stays
        }
        let destination = destinationDirectory.appendingPathComponent(fileURL.lastPathComponent)
        guard destination.standardizedFileURL != fileURL.standardizedFileURL else {
            return stays
        }
        // The year folder the file sits in lies above the scanned folder; its correct sibling
        // is out of reach. Report it instead of silently counting it as organized.
        guard isWithinRoot(destination, rootDirectory: rootDirectory) else {
            return .outsideScannedFolder(year: placement.year)
        }

        return .move(LocalMediaOrganizationItem(
            sourceURL: fileURL,
            sourceRelativePath: relativePath,
            destinationURL: destination,
            destinationRelativePath: makeRelativePath(for: destination, root: rootDirectory),
            proposedDate: placement.evidence.date,
            proposedSource: placement.evidence.source,
            isVideo: isVideo,
            destinationWasRenamed: false,
            rootDirectory: rootDirectory,
            groupsWithPhotos: groupsWithPhotos
        ))
    }

    /// `PARENT/YYYY[/_Filmy]`, or the sibling year folder when the file already sits under a
    /// year folder. nil when the file is already in the right year (and video) folder.
    private static func destinationDirectory(for parent: URL, year: String, placesAsVideo: Bool) -> URL? {
        let anchor: URL
        var preservedDirectories: [String] = []
        var prependVideoDirectory = placesAsVideo

        if let currentYearDirectory = nearestYearDirectory(startingAt: parent) {
            preservedDirectories = relativeDirectoryComponents(from: currentYearDirectory, to: parent)
            let isInVideoDirectory = preservedDirectories.contains(videoDirectoryName)
            if currentYearDirectory.lastPathComponent == year, placesAsVideo == isInVideoDirectory {
                return nil
            }
            if placesAsVideo {
                prependVideoDirectory = false
                if !isInVideoDirectory {
                    preservedDirectories.append(videoDirectoryName)
                }
            } else {
                preservedDirectories.removeAll { $0 == videoDirectoryName }
            }
            anchor = currentYearDirectory.deletingLastPathComponent()
        } else {
            anchor = parent
        }

        var destinationDirectory = anchor.appendingPathComponent(year, isDirectory: true)
        if prependVideoDirectory {
            destinationDirectory.appendPathComponent(videoDirectoryName, isDirectory: true)
        }
        for component in preservedDirectories {
            destinationDirectory.appendPathComponent(component, isDirectory: true)
        }
        return destinationDirectory
    }

    private static let livePhotoStillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]
    private static let livePhotoMotionExtensions: Set<String> = ["mov"]

    /// Maps each Live Photo motion file to its still: a `.mov` sharing the directory and the
    /// (case-insensitive) base name with a HEIC/JPEG.
    static func livePhotoCompanions(in relativePaths: [String]) -> [String: String] {
        var stillsByKey: [String: String] = [:]
        for path in relativePaths.sorted()
        where livePhotoStillExtensions.contains((path as NSString).pathExtension.lowercased()) {
            let key = pairKey(path)
            if stillsByKey[key] == nil {
                stillsByKey[key] = path
            }
        }
        var companions: [String: String] = [:]
        for path in relativePaths
        where livePhotoMotionExtensions.contains((path as NSString).pathExtension.lowercased()) {
            if let still = stillsByKey[pairKey(path)] {
                companions[path] = still
            }
        }
        return companions
    }

    private static func pairKey(_ relativePath: String) -> String {
        (relativePath as NSString).deletingPathExtension.lowercased()
    }

    /// Assigns collision-free destinations. Live Photo motion files are placed after their
    /// stills and reuse the still's final base name (`IMG (1).HEIC` → `IMG (1).MOV`) so the
    /// pair stays recognisable.
    static func resolveCollisions(
        _ candidates: [LocalMediaOrganizationItem],
        rootDirectory: URL,
        livePhotoCompanions: [String: String] = [:],
        fileManager: FileManager = .default
    ) -> [LocalMediaOrganizationItem] {
        var reservedPaths = Set<String>()
        let sorted = candidates.sorted {
            $0.sourceRelativePath.localizedStandardCompare($1.sourceRelativePath) == .orderedAscending
        }
        let motion = sorted.filter { livePhotoCompanions[$0.sourceRelativePath] != nil }
        let others = sorted.filter { livePhotoCompanions[$0.sourceRelativePath] == nil }

        var resolved: [String: LocalMediaOrganizationItem] = [:]
        for item in others {
            let destination = uniqueDestination(
                preferred: item.destinationURL,
                reservedPaths: &reservedPaths,
                fileManager: fileManager
            )
            resolved[item.sourceRelativePath] = item.moved(to: destination, root: rootDirectory)
        }
        for item in motion {
            var preferred = item.destinationURL
            if let stillPath = livePhotoCompanions[item.sourceRelativePath],
               let still = resolved[stillPath] {
                let base = still.destinationURL.deletingPathExtension().lastPathComponent
                preferred = still.destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(base)
                    .appendingPathExtension(item.destinationURL.pathExtension)
            }
            let destination = uniqueDestination(
                preferred: preferred,
                reservedPaths: &reservedPaths,
                fileManager: fileManager
            )
            resolved[item.sourceRelativePath] = item.moved(to: destination, root: rootDirectory)
        }
        return sorted.compactMap { resolved[$0.sourceRelativePath] }
    }

    private static func uniqueDestination(
        preferred: URL,
        reservedPaths: inout Set<String>,
        fileManager: FileManager
    ) -> URL {
        var candidate = preferred
        let base = preferred.deletingPathExtension().lastPathComponent
        let fileExtension = preferred.pathExtension
        var counter = 1

        while fileManager.fileExists(atPath: candidate.path)
            || reservedPaths.contains(candidate.standardizedFileURL.path) {
            let filename = fileExtension.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(fileExtension)"
            candidate = preferred.deletingLastPathComponent().appendingPathComponent(filename)
            counter += 1
        }
        reservedPaths.insert(candidate.standardizedFileURL.path)
        return candidate
    }

    /// Four ASCII digits forming a plausible photo year; `0815` or `9999` are ordinary folders.
    static func isYearDirectory(_ name: String) -> Bool {
        guard name.count == 4, name.allSatisfy({ $0.isASCII && $0.isNumber }), let year = Int(name) else {
            return false
        }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (1900...(currentYear + 1)).contains(year)
    }

    private static func nearestYearDirectory(startingAt directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        while candidate.path != "/" {
            if isYearDirectory(candidate.lastPathComponent) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return nil
    }

    private static func relativeDirectoryComponents(from ancestor: URL, to descendant: URL) -> [String] {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard descendantComponents.starts(with: ancestorComponents) else { return [] }
        return Array(descendantComponents.dropFirst(ancestorComponents.count))
    }

    private static func isWithinRoot(_ url: URL, rootDirectory: URL) -> Bool {
        let rootPath = canonicalPath(for: rootDirectory)
        let path = canonicalPath(for: url)
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    fileprivate static func relativePath(for url: URL, root: URL) -> String {
        makeRelativePath(for: url, root: root)
    }

    private static func makeRelativePath(for url: URL, root: URL) -> String {
        let rootPath = canonicalPath(for: root)
        let path = canonicalPath(for: url)
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func canonicalPath(for url: URL, fileManager: FileManager = .default) -> String {
        var existingURL = url.standardizedFileURL
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingURL.path) {
            let parent = existingURL.deletingLastPathComponent()
            guard parent.path != existingURL.path else { break }
            missingComponents.insert(existingURL.lastPathComponent, at: 0)
            existingURL = parent
        }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let didResolve = existingURL.path.withCString { path in
            buffer.withUnsafeMutableBufferPointer { pointer in
                realpath(path, pointer.baseAddress) != nil
            }
        }
        let existingPath = didResolve ? String(cString: buffer) : existingURL.path
        let completePath = missingComponents.reduce(URL(fileURLWithPath: existingPath)) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL.path
        return normalizePrivateSystemAlias(completePath)
    }

    private static func normalizePrivateSystemAlias(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] {
            let privateAlias = "/private\(alias)"
            if path == privateAlias || path.hasPrefix(privateAlias + "/") {
                return String(path.dropFirst("/private".count))
            }
        }
        return path
    }
}

// MARK: - Deciding year

extension LocalMediaOrganizationPlanner {
    /// The year a file belongs in, the evidence behind it and, for a file that stays in its
    /// year folder against a file-system date, that disagreeing date.
    private struct Placement {
        let year: String
        let evidence: FileDateEvidence
        let kept: FileDateEvidence?
    }

    /// Inside a year folder only embedded dates can move a file, and a New Year's Eve shoot
    /// stays in either neighbouring year. Elsewhere the oldest plausible date decides.
    private static func placement(
        in parent: URL,
        evidence: [FileDateEvidence],
        now: Date,
        timeZone: TimeZone
    ) -> Placement? {
        guard let overall = FileDateRepairPlanner.oldestPlausibleEvidence(in: evidence, now: now) else {
            return nil
        }
        guard let folderName = nearestYearDirectory(startingAt: parent)?.lastPathComponent,
              let folderYear = Int(folderName) else {
            return Placement(year: String(placementYear(for: overall.date, timeZone: timeZone)),
                             evidence: overall, kept: nil)
        }

        let embedded = FileDateRepairPlanner.oldestPlausibleEvidence(
            in: evidence.filter(\.source.isEmbeddedCreationDate),
            now: now
        )
        guard let embedded else {
            let agrees = placementYear(for: overall.date, timeZone: timeZone) == folderYear
                || isInNewYearWindow(overall.date, nextToYearFolder: folderYear, timeZone: timeZone)
            return Placement(year: folderName, evidence: overall, kept: agrees ? nil : overall)
        }
        if calendarYear(of: embedded.date, timeZone: timeZone) == folderYear
            || isInNewYearWindow(embedded.date, nextToYearFolder: folderYear, timeZone: timeZone) {
            return Placement(year: folderName, evidence: embedded, kept: nil)
        }
        return Placement(year: String(placementYear(for: embedded.date, timeZone: timeZone)),
                         evidence: embedded, kept: nil)
    }

    /// The calendar year, except that 1 January 00:00–05:59 local time counts as the
    /// previous year: the tail of a New Year's Eve party.
    static func placementYear(for date: Date, timeZone: TimeZone) -> Int {
        let parts = calendar(in: timeZone).dateComponents([.year, .month, .day, .hour], from: date)
        let year = parts.year ?? 0
        if parts.month == 1, parts.day == 1, let hour = parts.hour, hour < 6 {
            return year - 1
        }
        return year
    }

    /// True when the date falls in W(year) or W(year − 1), where W(Y) runs from 31 December Y
    /// 12:00 to 1 January Y+1 12:00 local time.
    static func isInNewYearWindow(_ date: Date, nextToYearFolder year: Int, timeZone: TimeZone) -> Bool {
        let calendar = calendar(in: timeZone)
        return [year, year - 1].contains { windowYear in
            guard let start = calendar.date(from: DateComponents(year: windowYear, month: 12, day: 31, hour: 12)),
                  let end = calendar.date(from: DateComponents(year: windowYear + 1, month: 1, day: 1, hour: 12)) else {
                return false
            }
            return date >= start && date < end
        }
    }

    private static func calendarYear(of date: Date, timeZone: TimeZone) -> Int {
        calendar(in: timeZone).component(.year, from: date)
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
