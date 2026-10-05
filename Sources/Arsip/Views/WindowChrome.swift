import AppKit
import SwiftUI

/// Arsip draws its own title bar row (tabs and buttons) as ordinary content instead of toolbar
/// items. Toolbar items are split per column and get re-laid out whenever the sidebar or inspector
/// resizes, which made them jump around.
enum TitleBar {
    /// The unified toolbar style's title bar height; the traffic lights are centered in it.
    static let height: CGFloat = 52
    /// Height of everything in the title bar row: tabs and the glass button groups.
    static let controlHeight: CGFloat = 32
    /// Clearance for the traffic lights (they end at x = 72) when the sidebar is hidden.
    static let trafficLightsInset: CGFloat = 80
}

/// Configures the hosting window: transparent, title-less, with an empty compact toolbar that only
/// provides the title bar height (clicks pass through to the content underneath).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfiguringView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "arsip.titlebar")
            }
            window.toolbar?.showsBaselineSeparator = false
            window.toolbarStyle = .unified
        }
    }
}

extension View {
    /// Lets an empty area act like a title bar: drag to move, double-click to zoom or minimize.
    func titleBarBehavior() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard let window = NSApp.keyWindow else { return }
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            })
    }
}

/// Thin divider on the inspector's leading edge that can be dragged to resize it.
struct InspectorResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double> = 280...760
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .leading))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start - value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
