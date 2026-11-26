import Foundation

enum ExternalDriveClassifier {
    static func classify(
        _ scan: FileDateScanOutputs,
        otherFiles: [String],
        otherFailures: [FileDateRepairFailure] = [],
        byteCount: (String) -> Int64,
        existsOnDestination: (String) -> Bool
    ) -> ExternalDriveReview {
        var entries: [ExternalDriveEntry] = []
        var readyUnits: [ExternalDriveUnit] = []
        var existingUnits: [ExternalDriveUnit] = []

        let classified = Dictionary(
            scan.outputs.map { ($0.relativePath, classify($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        var motionsByStill: [String: [String]] = [:]
        var pairedMotions: Set<String> = []
        for (motion, still) in scan.livePhotoCompanions
        where classified[motion] != nil && classified[still] != nil {
            motionsByStill[still, default: []].append(motion)
            pairedMotions.insert(motion)
        }

        for output in scan.outputs where !pairedMotions.contains(output.relativePath) {
            let members = [output.relativePath] + (motionsByStill[output.relativePath] ?? []).sorted()
            let outcome = classifyUnit(
                members: members, verdicts: members.compactMap { classified[$0] },
                byteCount: byteCount, existsOnDestination: existsOnDestination
            )
            entries += outcome.entries
            switch outcome.destination {
            case .ready(let unit): readyUnits.append(unit)
            case .existing(let unit): existingUnits.append(unit)
            case .held: break
            }
        }

        let scanFailurePaths = Set(scan.enumerationFailures.map(\.relativePath))
        let extraFailures = otherFailures.filter { !scanFailurePaths.contains($0.relativePath) }
        for failure in scan.enumerationFailures + extraFailures {
            entries.append(ExternalDriveEntry(
                relativePath: failure.relativePath, bucket: .problem, reason: failure.message,
                note: nil, byteCount: byteCount(failure.relativePath)
            ))
        }
        for path in otherFiles {
            entries.append(ExternalDriveEntry(
                relativePath: path, bucket: .notMedia, reason: nil, note: nil, byteCount: byteCount(path)
            ))
        }

        let order = { (lhs: String, rhs: String) in lhs.localizedStandardCompare(rhs) == .orderedAscending }
        return ExternalDriveReview(
            entries: entries.sorted { order($0.relativePath, $1.relativePath) },
            readyUnits: readyUnits.sorted { order($0.id, $1.id) },
            existingUnits: existingUnits.sorted { order($0.id, $1.id) }
        )
    }

    private enum UnitDestination {
        case ready(ExternalDriveUnit)
        case existing(ExternalDriveUnit)
        case held
    }

    private static func classifyUnit(
        members: [String],
        verdicts: [Verdict],
        byteCount: (String) -> Int64,
        existsOnDestination: (String) -> Bool
    ) -> (entries: [ExternalDriveEntry], destination: UnitDestination) {
        func entry(_ path: String, _ bucket: ExternalDriveBucket, _ reason: String?, _ note: String? = nil)
            -> ExternalDriveEntry {
            ExternalDriveEntry(
                relativePath: path, bucket: bucket, reason: reason, note: note, byteCount: byteCount(path)
            )
        }

        let blockers = zip(members, verdicts).filter { $0.1.bucket != .ready }
        if !blockers.isEmpty {
            let entries = zip(members, verdicts).map { path, verdict -> ExternalDriveEntry in
                guard verdict.bucket == .ready else { return entry(path, verdict.bucket, verdict.reason) }
                let partner = blockers.first { $0.0 != path }?.0 ?? path
                let name = (partner as NSString).lastPathComponent
                return entry(path, .needsOrganizing, "Its Live Photo pair “\(name)” needs organizing")
            }
            return (entries, .held)
        }

        let unit = ExternalDriveUnit(relativePaths: members, byteCount: members.reduce(0) { $0 + byteCount($1) })
        let existingCount = members.filter(existsOnDestination).count
        if existingCount == 0 {
            return (zip(members, verdicts).map { entry($0, .ready, nil, $1.note) }, .ready(unit))
        }
        if existingCount == members.count {
            return (members.map { entry($0, .alreadyOnDestination, nil) }, .existing(unit))
        }
        let reason = "Part of this Live Photo is already on the drive"
        return (members.map { entry($0, .problem, reason) }, .held)
    }

    /// Relative paths of visible regular files that are not supported media, and the visible entries that
    /// couldn't be read (supported media is the scanner's to report). Skips hidden entries, packages and
    /// symlinks like the scanner.
    static func otherFiles(
        in root: URL,
        supportedExtensions: Set<String>,
        resourceValues: (URL, Set<URLResourceKey>) throws -> URLResourceValues = { try $0.resourceValues(forKeys: $1) }
    ) -> (paths: [String], failures: [FileDateRepairFailure]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return ([], []) }

        var result: [String] = []
        var failures: [FileDateRepairFailure] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try resourceValues(url, Set(keys))
            } catch {
                if !url.lastPathComponent.hasPrefix("."),
                   !FileDateRepairExtensions.supports(url, extensions: supportedExtensions) {
                    failures.append(FileDateRepairFailure(
                        relativePath: relativePath(for: url, root: root), message: error.localizedDescription))
                }
                continue
            }
            if url.lastPathComponent.hasPrefix(".") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true || values.isPackage == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  !FileDateRepairExtensions.supports(url, extensions: supportedExtensions) else { continue }
            result.append(relativePath(for: url, root: root))
        }
        return (result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, failures)
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private struct Verdict {
        let bucket: ExternalDriveBucket
        let reason: String?
        let note: String?
    }

    static let notInYearFolderReason = "Not inside a year folder (choose a folder above the year folders)"

    private static func classify(_ output: FileDateScanOutput) -> Verdict {
        if let failure = output.failure {
            return Verdict(bucket: .needsOrganizing, reason: failure.message, note: nil)
        }
        if let conversion = output.conversionCandidate {
            return Verdict(bucket: .needsOrganizing, reason: "Conversion pending: \(conversion.kind.label)", note: nil)
        }
        if output.repairItem != nil {
            return Verdict(bucket: .needsOrganizing, reason: "Dates don't match", note: nil)
        }
        if let item = output.organizationCandidate {
            let directory = (item.destinationRelativePath as NSString).deletingLastPathComponent
            return Verdict(bucket: .needsOrganizing, reason: "Wrong folder (→ \(directory))", note: nil)
        }
        if let year = output.outsideScannedFolderYear {
            return Verdict(
                bucket: .needsOrganizing,
                reason: "Belongs in a “\(year)” folder outside the source folder",
                note: nil
            )
        }
        if !output.hasUsableDate {
            return Verdict(bucket: .needsOrganizing, reason: "No usable date", note: nil)
        }
        // A file above the year folders would land on the drive outside any year folder.
        let folders = (output.relativePath as NSString).deletingLastPathComponent.split(separator: "/")
        guard folders.contains(where: { LocalMediaOrganizationPlanner.isYearDirectory(String($0)) }) else {
            return Verdict(bucket: .needsOrganizing, reason: notInYearFolderReason, note: nil)
        }
        let notes = output.notices.map(\.message)
        return Verdict(bucket: .ready, reason: nil, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }
}
