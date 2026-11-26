import AppKit
import SwiftUI

/// Top-level view. Shows the launch permissions explainer first (when Photos access is
/// undetermined), then routes between the home screen and the organizing modes.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.showsPermissionsOnboarding {
                PermissionsOnboardingView()
            } else {
                switch appState.route {
                case .home:
                    HomeView()
                case .photos:
                    PhotosModeView()
                case .drone:
                    DroneModeView(workflow: appState.droneWorkflow)
                case .localPhotos:
                    LocalPhotosModeView(service: appState.localPhotosService)
                }
            }
        }
        .background {
            MainWindowAccessor { appState.mainWindow = $0 }
            if !appState.showsPermissionsOnboarding {
                MainWindowKeyboardShortcuts()
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = appState.notice {
                CommandNoticeBanner(message: notice.message) {
                    appState.notice = nil
                }
                .id(notice.id)
                .padding(.bottom, 20)
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: appState.route)
        .animation(.smooth(duration: 0.25), value: appState.showsPermissionsOnboarding)
        .animation(.smooth(duration: 0.2), value: appState.notice)
    }
}

/// Explains why a shortcut or button could not run right now. Click to dismiss; it also
/// fades out on its own.
private struct CommandNoticeBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 560)
            .liquidGlassCard(cornerRadius: 14)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel(message)
        .accessibilityHint("Dismisses the message")
    }
}

/// Reports the `NSWindow` hosting the SwiftUI hierarchy, so commands can tell the main
/// window apart from sheets, panels and Settings.
private struct MainWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
