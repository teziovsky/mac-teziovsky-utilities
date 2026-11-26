import Foundation

/// An original that an earlier "keep originals" conversion marked, next to the converted
/// copy it produced. Replacing the original with the copy leaves one file under the
/// original's name.
struct LocalMediaReplaceablePair: Identifiable, Sendable, Equatable {
    var id: String { originalRelativePath }
    let originalURL: URL
    let originalRelativePath: String
    let copyURL: URL
    let copyRelativePath: String
    /// The original's base name with the copy's extension.
    let finalName: String
    let isVideo: Bool

    /// The pair for `originalURL`, or nil when it carries no conversion marker, the marked
    /// twin is missing, is not a regular file or is the original itself.
    static func detect(
        originalURL: URL,
        relativePath: String,
        isVideo: Bool
    ) -> LocalMediaReplaceablePair? {
        guard let twinName = LocalMediaConverter.convertedTwinName(of: originalURL),
              !twinName.isEmpty,
              twinName != ".", twinName != "..",
              !twinName.contains("/") else { return nil }
        let copyURL = originalURL.deletingLastPathComponent().appendingPathComponent(twinName)
        var info = stat()
        var originalInfo = stat()
        guard lstat(copyURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              lstat(originalURL.path, &originalInfo) == 0,
              info.st_dev != originalInfo.st_dev || info.st_ino != originalInfo.st_ino else { return nil }
        let relativeDirectory = (relativePath as NSString).deletingLastPathComponent
        let copyRelativePath = relativeDirectory.isEmpty ? twinName : relativeDirectory + "/" + twinName
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let copyExtension = copyURL.pathExtension
        return LocalMediaReplaceablePair(
            originalURL: originalURL,
            originalRelativePath: relativePath,
            copyURL: copyURL,
            copyRelativePath: copyRelativePath,
            finalName: copyExtension.isEmpty ? baseName : baseName + "." + copyExtension,
            isVideo: isVideo
        )
    }

    /// Sorted pairs without chains: a file that is both a copy and an original (A to B to C,
    /// or A and B pointing at each other) takes both of its links out, so it is never replaced.
    /// A copy claimed by several originals (A to C and B to C) takes all of them out too.
    static func sorted(_ pairs: [LocalMediaReplaceablePair]) -> [LocalMediaReplaceablePair] {
        let originals = Set(pairs.map(\.originalRelativePath))
        let copyCounts = Dictionary(pairs.map { ($0.copyRelativePath, 1) }, uniquingKeysWith: +)
        return pairs.filter {
            copyCounts[$0.originalRelativePath] == nil
                && !originals.contains($0.copyRelativePath)
                && copyCounts[$0.copyRelativePath] == 1
        }.sorted { $0.originalRelativePath.localizedStandardCompare($1.originalRelativePath) == .orderedAscending }
    }
}

/// What a "Replace Originals" run did. A pair cancelled mid-check, or never tried because the
/// run was cancelled, counts as cancelled, not failed.
struct LocalMediaReplacementSummary: Sendable, Equatable {
    var replaced = 0
    /// The original is in the Trash, but the copy kept its own name.
    var keptCopyName = 0
    var failed = 0
    var cancelled = 0
    var total = 0
    /// The pairs that were not fully replaced (failed or kept the copy's name), with the reason.
    var issues: [FileDateRepairFailure] = []
}
