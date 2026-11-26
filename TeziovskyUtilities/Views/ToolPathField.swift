import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A path field for an external tool with a "Choose…" button and a live status line that
/// says which binary or app will actually be used.
struct ToolPathField: View {
    enum Kind {
        case commandLineTool
        case application
    }

    let title: String
    @Binding var path: String
    let kind: Kind
    let status: DroneToolStatus
    let missingHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(title, text: $path, prompt: Text("Auto-detect"))
                Button("Choose…", action: choose)
            }
            Label(statusText, systemImage: statusSymbol)
                .font(AlbumListRowStyle.detailFont)
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch status {
        case .configured(let url):
            return "Using \(DroneFormat.abbreviatedPath(url.path))"
        case .autoDetected(let url, let configuredPathIsInvalid):
            let found = DroneFormat.abbreviatedPath(url.path)
            return configuredPathIsInvalid
                ? "The path above does not exist — using \(found) instead"
                : "Found automatically at \(found)"
        case .notFound(let configuredPathIsInvalid):
            return configuredPathIsInvalid
                ? "The path above does not exist and nothing was found automatically. \(missingHint)"
                : "Not found. \(missingHint)"
        }
    }

    private var statusSymbol: String {
        switch status {
        case .configured, .autoDetected(_, configuredPathIsInvalid: false):
            return "checkmark.circle.fill"
        case .autoDetected:
            return "exclamationmark.triangle.fill"
        case .notFound:
            return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .configured, .autoDetected(_, configuredPathIsInvalid: false):
            return .green
        case .autoDetected:
            return .orange
        case .notFound:
            return .red
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        switch kind {
        case .commandLineTool:
            panel.message = "Choose the \(title) executable."
            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        case .application:
            panel.message = "Choose \(title)."
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
