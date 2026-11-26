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
    static func sorted(_ pairs: [LocalMediaReplaceablePair]) -> [LocalMediaReplaceablePair] {
        let originals = Set(pairs.map(\.originalRelativePath))
        let copies = Set(pairs.map(\.copyRelativePath))
        return pairs.filter {
            !copies.contains($0.originalRelativePath) && !originals.contains($0.copyRelativePath)
        }.sorted { $0.originalRelativePath.localizedStandardCompare($1.originalRelativePath) == .orderedAscending }
    }
}
