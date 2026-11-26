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
            folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        var allFileIndexes: [Int] {
            (fileIndexes + folders.values.flatMap(\.allFileIndexes)).sorted()
        }
    }

    static func rows(paths: [String], collapsed: Set<String>) -> [LocalMediaTreeRow] {
        let root = Node(name: "")
        for (index, path) in paths.enumerated() {
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
