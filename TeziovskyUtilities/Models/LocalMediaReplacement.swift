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
              twinName != originalURL.lastPathComponent,
              !twinName.contains("/") else { return nil }
        let copyURL = originalURL.deletingLastPathComponent().appendingPathComponent(twinName)
        var info = stat()
        guard lstat(copyURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
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

    static func sorted(_ pairs: [LocalMediaReplaceablePair]) -> [LocalMediaReplaceablePair] {
        pairs.sorted { $0.originalRelativePath.localizedStandardCompare($1.originalRelativePath) == .orderedAscending }
    }
}
