import Foundation

/// One line of a review list shown as a folder tree.
struct LocalMediaTreeRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// `filePaths` lists every file under the folder, recursively.
        case folder(path: String, title: String, filePaths: [String])
        /// `index` points into the `paths` the tree was built from.
        case file(index: Int)
    }

    let kind: Kind
    let depth: Int
    /// Needed by `id` for file rows; folders ignore it.
    fileprivate let filePath: String

    init(kind: Kind, depth: Int, filePath: String = "") {
        self.kind = kind
        self.depth = depth
        self.filePath = filePath
    }

    var id: String {
        switch kind {
        case let .folder(path, _, _): return "d:" + path
        case .file: return "f:" + filePath
        }
    }
}

/// How many of a folder's files are currently included.
enum LocalMediaFolderSelection {
    case all, some, none
}

/// Turns relative paths into folder headers and file rows; single-child folders are merged
/// into one header ("Festiwale/Audioriver/2023").
enum LocalMediaTree {
    private final class Node {
        let name: String
        var folders: [String: Node] = [:]
        var fileIndexes: [Int] = []

        init(name: String) { self.name = name }

        var sortedFolders: [Node] {
            folders.values.sorted {
                switch $0.name.localizedStandardCompare($1.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return $0.name < $1.name
                }
            }
        }

        var allFileIndexes: [Int] {
            (fileIndexes + folders.values.flatMap(\.allFileIndexes)).sorted()
        }
    }

    static func rows(paths: [String], collapsed: Set<String>) -> [LocalMediaTreeRow] {
        let root = Node(name: "")
        var seen = Set<String>()
        for (index, path) in paths.enumerated() {
            guard seen.insert(path).inserted else { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            for folder in parts.dropLast() {
                if let next = node.folders[folder] {
                    node = next
                } else {
                    let next = Node(name: folder)
                    node.folders[folder] = next
                    node = next
                }
            }
            node.fileIndexes.append(index)
        }
        var walk = Walk(paths: paths, collapsed: collapsed)
        walk.append(root, parentPath: "", depth: 0)
        return walk.rows
    }

    private struct Walk {
        let paths: [String]
        let collapsed: Set<String>
        var rows: [LocalMediaTreeRow] = []

        mutating func append(_ node: Node, parentPath: String, depth: Int) {
            for child in node.sortedFolders {
                var merged = child
                var title = child.name
                var path = parentPath.isEmpty ? child.name : parentPath + "/" + child.name
                while merged.fileIndexes.isEmpty, merged.folders.count == 1, let only = merged.folders.values.first {
                    merged = only
                    title += "/" + only.name
                    path += "/" + only.name
                }
                rows.append(LocalMediaTreeRow(
                    kind: .folder(path: path, title: title, filePaths: merged.allFileIndexes.map { paths[$0] }),
                    depth: depth
                ))
                guard !collapsed.contains(path) else { continue }
                append(merged, parentPath: path, depth: depth + 1)
            }
            for index in node.fileIndexes {
                rows.append(LocalMediaTreeRow(kind: .file(index: index), depth: depth, filePath: paths[index]))
            }
        }
    }
}

extension LocalMediaTree {
    /// The rows to render while only `fileLimit` file rows are shown; folder headers don't
    /// count. `isTruncated` means some file rows are behind "Show all".
    static func limitedRows(
        _ rows: [LocalMediaTreeRow],
        fileLimit: Int
    ) -> (rows: [LocalMediaTreeRow], isTruncated: Bool) {
        let fileRowCount = rows.filter { if case .file = $0.kind { true } else { false } }.count
        guard fileRowCount > fileLimit else { return (rows, false) }
        var visible: [LocalMediaTreeRow] = []
        var emittedFiles = 0
        for row in rows {
            guard emittedFiles < fileLimit else { break }
            visible.append(row)
            if case .file = row.kind { emittedFiles += 1 }
        }
        return (visible, true)
    }
}

extension LocalMediaFolderSelection {
    /// Clicking a fully included folder excludes it; a partly or fully excluded one is included.
    var excludesOnClick: Bool { self == .all }

    var checkboxSymbol: String {
        switch self {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }

    var checkboxHelp: String {
        excludesOnClick ? "Exclude all files in this folder" : "Include all files in this folder"
    }
}
