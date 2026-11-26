import SwiftUI

/// The review rows matching the filter, grouped under folder headers with a tri-state
/// checkbox per folder; capped at `localMediaListRowLimit` file rows until "Show all".
struct LocalMediaTreeList<Item: Identifiable, Row: View>: View {
    @ObservedObject var service: LocalPhotosService
    let items: [Item]
    let path: (Item) -> String
    let filter: String
    let step: LocalMediaStep
    @ViewBuilder let row: (Item) -> Row
    @State private var collapsed: Set<String> = []
    @State private var showsAll = false
    @State private var cache = LocalMediaTreeCache()

    /// Indent per tree level; also the chevron's width plus spacing, so a folder's checkbox
    /// sits in the same column as its files' checkboxes.
    private static var indent: CGFloat { 18 }

    var body: some View {
        let tree = cache.tree(paths: items.map(path), filter: filter, collapsed: collapsed)
        let matching = tree.matching.map { items[$0] }
        let rows = tree.rows
        let limited = showsAll
            ? (rows: rows, isTruncated: false)
            : LocalMediaTree.limitedRows(rows, fileLimit: localMediaListRowLimit)
        LazyVStack(spacing: 8) {
            if matching.isEmpty {
                Text("No files match “\(filter.trimmingCharacters(in: .whitespaces))”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(limited.rows) { treeRow in
                switch treeRow.kind {
                case let .folder(folderPath, title, filePaths):
                    folderHeader(path: folderPath, title: title, filePaths: filePaths)
                        .padding(.leading, Self.indent * CGFloat(treeRow.depth))
                case let .file(index):
                    row(matching[index])
                        .padding(.leading, Self.indent * CGFloat(treeRow.depth))
                }
            }
            if limited.isTruncated {
                Button("Show all \(matching.count) files") {
                    showsAll = true
                }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func folderHeader(path folderPath: String, title: String, filePaths: [String]) -> some View {
        let isCollapsed = collapsed.contains(folderPath)
        let selection = service.selection(of: filePaths, in: step)
        return HStack(alignment: .localMediaRowAnchor, spacing: 6) {
            Button {
                if isCollapsed {
                    collapsed.remove(folderPath)
                } else {
                    collapsed.insert(folderPath)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.indent - 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(title)" : "Collapse \(title)")
            .help(isCollapsed ? "Show the files in this folder" : "Hide the files in this folder")

            Button {
                service.setExcluded(selection.excludesOnClick, paths: filePaths, in: step)
            } label: {
                Image(systemName: selection.checkboxSymbol)
                    .foregroundStyle(selection == .none ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .localMediaRowAnchor()
            .disabled(service.isRunning)
            .help(selection.checkboxHelp)
            .accessibilityLabel(selection.checkboxAccessibilityLabel(folder: title))
            .accessibilityValue(accessibilityValue(for: selection))

            Text(title)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(filePaths.count) files")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessibilityValue(for selection: LocalMediaFolderSelection) -> String {
        switch selection {
        case .all: "All included"
        case .some: "Some included"
        case .none: "None included"
        }
    }
}
