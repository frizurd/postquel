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

    /// Height of controls in bottom bars: the same as the sidebar's database button and the title bar's.
    static var barControlHeight: CGFloat { TitleBar.controlHeight }

    /// Bottom bars of tabs. On macOS 26 they match the sidebar footer, a 32pt glass button with
    /// 10pt around it, so controls line up along the bottom of the window.
    static var bottomBarHeight: CGFloat {
        if #available(macOS 26, *) { barControlHeight + 20 } else { barHeight }
    }
}

extension View {
    /// Status strips at the bottom of panes: quiet text, consistent height and padding.
    func statusBar() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Theme.barHeight)
    }

    /// The bar along the bottom of a tab: same text style as `statusBar`, sized to line up with the sidebar footer.
    func bottomBar() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: Theme.bottomBarHeight)
    }

    /// Buttons in bottom bars: 32pt glass capsules on macOS 26, `SoftButtonStyle` before.
    @ViewBuilder
    func barButtonStyle(prominent: Bool = false, tint: Color = .accentColor) -> some View {
        if #available(macOS 26, *) {
            buttonStyle(BarGlassButtonStyle(prominent: prominent, tint: tint))
        } else {
            buttonStyle(SoftButtonStyle(prominent: prominent, tint: tint))
        }
    }

    /// Keeps a view built but out of sight and inert, so switching back to it is instant: no clicks,
    /// no keyboard shortcuts (a hidden tab's ⌘S or ⌘↩ must not fire), hidden from accessibility.
    func inactive(_ isInactive: Bool) -> some View {
        opacity(isInactive ? 0 : 1)
            .allowsHitTesting(!isInactive)
            .disabled(isInactive)
            .accessibilityHidden(isInactive)
    }

    /// Section label above a group of controls.
    func sectionLabel() -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}

// MARK: Liquid Glass
// Controls that float above content get Liquid Glass on macOS 26 and later. Earlier systems keep
// the material-and-hairline look these helpers replace.

extension View {
    /// A floating surface: glass, or a material panel with a hairline before macOS 26.
    /// The glass is drawn behind the content rather than wrapping it: AppKit-backed controls
    /// (text fields) inside a `glassEffect` end up in a layer that's neither drawn nor clickable.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            background {
                Color.clear.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            }
        } else {
            background(.regularMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.12), in: shape)
                .overlay(shape.strokeBorder(.quaternary))
        }
    }

    /// Glass on macOS 26 and later; unchanged before, for things that had no surface of their own.
    @ViewBuilder
    func glassOnly<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            self
        }
    }

    /// Groups nearby glass so it blends and morphs as one.
    @ViewBuilder
    func glassGroup(spacing: CGFloat? = nil) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Glass buttons on macOS 26 and later, `SoftButtonStyle` before.
    @ViewBuilder
    func softButtonStyle(prominent: Bool = false, tint: Color = .accentColor) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(tint)
            } else {
                buttonStyle(.glass)
            }
        } else {
            buttonStyle(SoftButtonStyle(prominent: prominent, tint: tint))
        }
    }

    /// A bar pinned to an edge that content scrolls under. On macOS 26 it gets the soft scroll
    /// edge effect and no background of its own, so glass controls in it float over the content.
    @ViewBuilder
    func floatingBar<Content: View>(edge: VerticalEdge, @ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: 0) { content().background(.bar) }
        }
    }

    /// `.bar` behind strips before macOS 26; on 26 the surrounding glass or scroll edge effect does that job.
    @ViewBuilder
    func legacyBarBackground() -> some View {
        if #available(macOS 26, *) {
            self
        } else {
            background(.bar)
        }
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

/// A 32pt glass capsule, so bar buttons match the sidebar's database button exactly. The system
/// glass styles size themselves by control size, which doesn't land on 32pt.
@available(macOS 26, *)
struct BarGlassButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, prominent: prominent, tint: tint)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 14)
                .frame(height: Theme.barControlHeight)
                .contentShape(Capsule())
                .glassEffect(prominent ? .regular.tint(tint).interactive(isEnabled) : .regular.interactive(isEnabled), in: Capsule())
                .opacity(isEnabled ? 1 : 0.6)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Segmented control drawn as one glass capsule with a neutral highlight on the selected segment,
/// sized like the other bar controls.
struct GlassSegmentedPicker<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 12)
                        .frame(height: Theme.barControlHeight - 6)
                        .background {
                            if isSelected {
                                // A neutral thumb like the system's glass segmented control: white at low
                                // opacity in dark mode, black at low opacity in light mode.
                                Capsule()
                                    .fill(Color.primary.opacity(0.14))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassSurface(Capsule())
    }
}
