import AppKit
import SwiftUI

enum AlbumListRowStyle {
    // MARK: - Settings rows (two-line, no icon)

    static let cornerRadius: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
    static let labelSpacing: CGFloat = 4

    static let nameFont: Font = .system(size: 15, weight: .medium)
    static let detailFont: Font = .system(size: 13)
    static let toolbarTitleFont: Font = .system(size: 17, weight: .semibold)
    static let navigationAlbumTitleFont: Font = .system(size: 15, weight: .semibold)
    static let navigationAlbumDetailFont: Font = .system(size: 12)

    static var hoverFill: Color {
        Color(nsColor: .quaternarySystemFill)
    }

    // MARK: - Sidebar

    static let sidebarIconName = "rectangle.stack"
}

/// Settings: album name and media summary (no icon).
struct AlbumListRowLabels: View {
    let album: PhotoAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: AlbumListRowStyle.labelSpacing) {
            Text(album.name)
                .font(AlbumListRowStyle.nameFont)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(album.mediaSummary)
                .font(AlbumListRowStyle.detailFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Pads the row and defines hit testing to match the hover/selection background (Settings).
    func albumListRowChrome(backgroundFill: Color) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AlbumListRowStyle.horizontalPadding)
            .padding(.vertical, AlbumListRowStyle.verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: AlbumListRowStyle.cornerRadius)
                    .fill(backgroundFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: AlbumListRowStyle.cornerRadius))
    }

    /// Applies a Liquid Glass surface (macOS 26+) with a material fallback on earlier systems.
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(shape.fill(.regularMaterial))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .clipShape(shape)
        }
    }
}

extension View {
    /// A rounded "pill" action button matching the app's Liquid Glass look, complete with the
    /// system focus ring. Uses the macOS 26 glass button styles, with a bordered fallback.
    @ViewBuilder
    func pillActionButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            } else {
                buttonStyle(.glass)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            } else {
                buttonStyle(.bordered)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            }
        }
    }
}

extension View {
    /// Runs `action` when Escape is pressed anywhere in the view's window.
    ///
    /// Uses a hidden `.cancelAction` button (registered as a window key-equivalent) which is
    /// far more reliable than `onExitCommand`, that only fires when the view is first responder.
    func onEscape(perform action: @escaping () -> Void) -> some View {
        background(
            Button("Back", action: action)
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        )
    }
}

/// A content card rendered with a Liquid Glass surface, matching the app's glass look.
struct GlassCard<Content: View>: View {
    var title: String?
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .liquidGlassCard(cornerRadius: cornerRadius)
    }
}
