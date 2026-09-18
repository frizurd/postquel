import AppKit
import SwiftUI

/// Shared look: calm surfaces, soft separators, generous rows, one accent.
enum Theme {
    static let corner: CGFloat = 8
    static let smallCorner: CGFloat = 6
    /// Height of the status/footer strips.
    static let barHeight: CGFloat = 32
    static let gridRowHeight: CGFloat = 28

    static var separator: NSColor { .separatorColor.withAlphaComponent(0.55) }
}

extension View {
    /// Status strips at the bottom of panes: quiet text, consistent height and padding.
    func statusBar() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Theme.barHeight)
    }

    /// Section label above a group of controls.
    func sectionLabel() -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}

/// Quiet bordered button used across panes.
struct SoftButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, prominent: prominent, tint: tint)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                        .strokeBorder(prominent ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.quaternary))
                )
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }

        private var background: AnyShapeStyle {
            if prominent {
                return AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.8 : 1))
            }
            if configuration.isPressed { return AnyShapeStyle(.tertiary) }
            return isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear)
        }
    }
}
