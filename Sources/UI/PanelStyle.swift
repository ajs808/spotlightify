import AppKit
import SwiftUI

enum SearchPanelLayout {
    /// The visible rounded card.
    static let cardWidth: CGFloat = 760
    static let cardHeight: CGFloat = 660
    static let cornerRadius: CGFloat = 26
    /// Small transparent inset keeps the rounded material clear of the square window edge.
    static let windowInset: CGFloat = 12
    static let windowWidth = cardWidth + windowInset * 2
    static let windowHeight = cardHeight + windowInset * 2
    /// Width of the artists / albums / detail column beside the songs.
    static let browseColumnWidth: CGFloat = 310
}

enum PlaybackTime {
    static func format(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "--:--" }
        let totalSeconds = max(0, milliseconds / 1_000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct NativePanelSurface: ViewModifier {
    let reduceTransparency: Bool
    let appearance: AppearancePreference

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(.rect(cornerRadius: SearchPanelLayout.cornerRadius))
        } else {
            content
                .background {
                    PanelMaterial(appearance: appearance)
                        .clipShape(.rect(cornerRadius: SearchPanelLayout.cornerRadius))
                }
                .clipShape(.rect(cornerRadius: SearchPanelLayout.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: SearchPanelLayout.cornerRadius, style: .continuous)
                        .strokeBorder(Color.separator.opacity(0.65), lineWidth: 1)
                }
        }
    }
}

struct SelectedModeSurface: ViewModifier {
    let isSelected: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected, !reduceTransparency, #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else if isSelected {
            content.background(Color.overlayInk.opacity(0.10), in: .capsule)
        } else {
            content
        }
    }
}

struct NativeGlassBackground: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

struct NativeGlassButtonStyle: ViewModifier {
    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct PanelMaterial: NSViewRepresentable {
    let appearance: AppearancePreference

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = appearance.appKitAppearance
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = appearance.appKitAppearance
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

extension AppearancePreference {
    var symbolName: String {
        switch self {
        case .system:
            return "display"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

extension Color {
    static let panelCanvas = Color(nsColor: .windowBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    static let inkMuted = Color(nsColor: .secondaryLabelColor)
    static let inkFaint = Color(nsColor: .secondaryLabelColor).opacity(0.85)
    static let overlayInk = Color(nsColor: .labelColor)
    static let onPrimary = Color(nsColor: .windowBackgroundColor)
    static let panelShadow = Color(nsColor: .shadowColor)
    static let separator = Color(nsColor: .separatorColor)
    static let playingDot = Color(nsColor: NSColor(calibratedRed: 0.337, green: 0.827, blue: 0.392, alpha: 1.0))
}
