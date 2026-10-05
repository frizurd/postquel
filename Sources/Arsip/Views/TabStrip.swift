import SwiftUI

/// Compact, Safari-style tabs shown in the window's title bar.
struct TabStrip: View {
    @Bindable var session: SessionModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabs) { tab in
                        TabButton(
                            title: tab.title,
                            symbol: tab.symbol,
                            isActive: tab.id == session.activeTabID,
                            select: { session.activate(tab.id) },
                            close: { session.closeTab(tab.id) }
                        )
                        .id(tab.id)
                    }
                }
            }
            .onChange(of: session.activeTabID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .background {
            // ⌘W closes the active tab instead of the window while tabs are open.
            Button("Close Tab") {
                if let id = session.activeTabID { session.closeTab(id) }
            }
            .keyboardShortcut("w")
            .disabled(session.activeTabID == nil)
            .opacity(0)
            .allowsHitTesting(false)
        }
    }
}

/// Title bar buttons at the trailing end of the top bar.
struct TitlebarActions: View {
    let session: SessionModel
    @Binding var showsInspector: Bool
    @Binding var inspectorMode: InspectorMode

    var body: some View {
        HStack(spacing: 2) {
            // ⌘T still opens a query tab; the sidebar's New Query row is the visible way in.
            Button("New Query Tab") { session.openQueryTab() }
                .keyboardShortcut("t")
                .frame(width: 0, height: 0)
                .opacity(0)

            Button { Task { await session.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Reload tables and the current tab (⌘R)")

            Button { toggleInspector(.assistant) } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(TitlebarIconButtonStyle(isOn: showsInspector && inspectorMode == .assistant))
            .keyboardShortcut("k")
            .help("Ask the assistant about this database (⌘K)")

            Button { toggleInspector(.value) } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(TitlebarIconButtonStyle(isOn: showsInspector && inspectorMode == .value))
            .keyboardShortcut("i")
            .help("Value inspector (⌘I)")
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .padding(2)
        .glassOnly(Capsule())
    }

    /// Shows the inspector in `mode`, or hides it if it's already showing that.
    private func toggleInspector(_ mode: InspectorMode) {
        if showsInspector, inspectorMode == mode {
            showsInspector = false
        } else {
            inspectorMode = mode
            showsInspector = true
        }
    }
}

/// Square icon button: faint background on hover, stronger while pressed.
struct TitlebarIconButtonStyle: ButtonStyle {
    /// Tints the icon, for buttons that toggle a panel.
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, isOn: isOn)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let isOn: Bool
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 28, height: 28)
                .background(
                    shape.fill(configuration.isPressed ? AnyShapeStyle(.tertiary)
                               : isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear))
                )
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }

        /// Round on macOS 26, to sit concentrically in the glass capsules around these buttons.
        private var shape: AnyShape {
            if #available(macOS 26, *) {
                AnyShape(Circle())
            } else {
                AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

private struct TabButton: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary).opacity(isHovered ? 1 : 0))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered || isActive ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        // One weight for every tab: a bolder active tab would be wider and shift its neighbours.
        .font(.system(size: 13, weight: .medium))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minWidth: 120, maxWidth: 220)
        .frame(height: TitleBar.controlHeight)
        .modifier(TabBackground(isActive: isActive, isHovered: isHovered))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .help(title)
    }
}

/// The active tab is a glass capsule on macOS 26; before that, a filled, outlined rounded rectangle.
private struct TabBackground: ViewModifier {
    let isActive: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if isActive {
                content.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                content.background(Capsule().fill(isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear)))
            }
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(.quaternary) : isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                        .strokeBorder(isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear))
                )
        }
    }
}
