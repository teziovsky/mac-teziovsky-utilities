import AppKit
import SwiftUI

/// Files that stay in their year folder because only file-system dates disagree.
struct LocalMediaKeptSection: View {
    let items: [LocalMediaKeptItem]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    LocalMediaKeptRow(item: item)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Kept in year folder — only file-system date disagrees (\(items.count))")
                .font(.headline)
        }
    }
}

private struct LocalMediaKeptRow: View {
    let item: LocalMediaKeptItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.relativePath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    "Folder \(item.yearFolder) kept · "
                        + "\(item.disagreeingDate.formatted(date: .abbreviated, time: .omitted)) "
                        + "from \(item.disagreeingSource.label)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            }
        }
    }
}
