import AppKit
import SwiftUI

/// Rows beyond this are behind "Show all", so folders with thousands of files stay responsive.
let localMediaListRowLimit = 300

extension VerticalAlignment {
    private enum LocalMediaRowAnchor: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    /// The line a file row's include checkbox lines up with. Rows mark their leading icon
    /// (the disclosure chevron or the file-type icon) with `localMediaRowAnchor()`, so the
    /// checkbox stays on the first line even when a row is expanded or wraps.
    static let localMediaRowAnchor = VerticalAlignment(LocalMediaRowAnchor.self)
}

extension View {
    /// Marks this view's vertical center as the line the row's include checkbox centers on.
    func localMediaRowAnchor() -> some View {
        alignmentGuide(.localMediaRowAnchor) { $0[VerticalAlignment.center] }
    }
}

/// A reviewable file row: an include checkbox (unticked files are left unchanged by that
/// step), dimming for excluded files and "Reveal in Finder" in the context menu.
struct LocalMediaSelectableRow<Content: View>: View {
    @ObservedObject var service: LocalPhotosService
    let path: String
    let fileURL: URL
    let step: LocalMediaStep
    @ViewBuilder let content: () -> Content

    private var isIncluded: Bool {
        !service.isExcluded(path: path, in: step)
    }

    var body: some View {
        HStack(alignment: .localMediaRowAnchor, spacing: 8) {
            Toggle(
                "Include \(path)",
                isOn: Binding(
                    get: { isIncluded },
                    set: { service.setExcluded(!$0, path: path, in: step) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .localMediaRowAnchor()
            .disabled(service.isRunning)
            .help(
                isIncluded ? "Included — untick to leave this file unchanged" : "Excluded — this file stays unchanged"
            )

            content()
                .opacity(isIncluded ? 1 : 0.45)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }
}

/// The rows matching the filter, capped at `localMediaListRowLimit` until "Show all".
struct LocalMediaFilteredList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let path: (Item) -> String
    let filter: String
    @ViewBuilder let row: (Item) -> Row
    @State private var showsAll = false

    var body: some View {
        let matching = items.filter { LocalMediaListFilter.matches(path($0), query: filter) }
        let visible = showsAll ? matching : Array(matching.prefix(localMediaListRowLimit))
        LazyVStack(spacing: 8) {
            if matching.isEmpty {
                Text("No files match “\(filter.trimmingCharacters(in: .whitespaces))”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(visible) { item in
                row(item)
            }
            if matching.count > visible.count {
                Button("Show all \(matching.count) files") {
                    showsAll = true
                }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Shown instead of the step previews when the last scan was cancelled or failed, so empty
/// lists are never presented as "nothing to do".
struct LocalMediaIncompleteScanCard: View {
    let message: String
    let rescan: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("The scan did not finish", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Rescan", action: rescan)
                        .pillActionButton(prominent: true)
                }
            }
        }
    }
}
