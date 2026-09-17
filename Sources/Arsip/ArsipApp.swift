import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // Claude Code launches this same binary as a stdio MCP server.
        if CommandLine.arguments.dropFirst().first == MCPServer.launchArgument {
            MCPServer.runFromEnvironment()
        } else {
            ArsipApp.main()
        }
    }
}

struct ArsipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Arsip") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @State private var session = SessionModel()

    var body: some View {
        Group {
            if session.isConnected {
                BrowserView(session: session)
            } else {
                ConnectView(session: session)
                    .task { await session.reconnectOnLaunchIfNeeded() }
            }
        }
        .background(WindowConfigurator())
    }
}

struct BrowserView: View {
    @Bindable var session: SessionModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("showsInspector") private var showsInspector = false
    @AppStorage("inspectorMode") private var inspectorMode = InspectorMode.value
    @AppStorage("inspectorWidth") private var inspectorWidth = 360.0
    @State private var showsQuickOpen = false

    private var isSidebarVisible: Bool { columnVisibility != .detailOnly }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(get: { session.sidebarSelection }, set: { session.sidebarSelected($0) })) {
                Section {
                    Label("SQL Query", systemImage: "terminal").tag(SidebarItem.query)
                }
                ForEach(session.filteredSchemas) { group in
                    Section(group.name) {
                        ForEach(group.relations) { relation in
                            Label(relation.name, systemImage: relation.kind.symbol)
                                .tag(SidebarItem.relation(relation))
                                .contextMenu {
                                    Button("Open in New Tab") { session.openTab(relation) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) { connectionHeader }
            .searchable(text: $session.sidebarFilter, placement: .sidebar, prompt: "Filter tables")
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                topBar
                Divider()
                HStack(spacing: 0) {
                    tabContents
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsInspector {
                        InspectorResizeHandle(width: $inspectorWidth)
                        InspectorPanel(session: session, mode: $inspectorMode)
                            .frame(width: inspectorWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(.snappy(duration: 0.25), value: showsInspector)
        }
        .navigationTitle(session.config.database)
        .background {
            // ⌘P anywhere in the window opens the table finder.
            Button("Find Table") { showsQuickOpen = true }
                .keyboardShortcut("p")
                .opacity(0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if showsQuickOpen {
                QuickOpenView(
                    relations: session.allRelations,
                    onOpen: { relation, inNewTab in
                        showsQuickOpen = false
                        if inNewTab {
                            session.openTab(relation)
                        } else {
                            session.sidebarSelected(.relation(relation))
                        }
                    },
                    onClose: { showsQuickOpen = false }
                )
                .padding(.top, 90)
                .transition(.quickOpen)
            }
        }
        .animation(.snappy(duration: 0.18), value: showsQuickOpen)
    }

    /// Tabs and buttons in the title bar row. The buttons are anchored to the detail column's
    /// trailing edge, which is always the window's right edge, so they never move.
    private var topBar: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.3)) {
                    columnVisibility = isSidebarVisible ? .detailOnly : .all
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(isSidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")

            TabStrip(session: session)
                .frame(maxWidth: .infinity, alignment: .leading)

            TitlebarActions(session: session, showsInspector: $showsInspector, inspectorMode: $inspectorMode)
        }
        .padding(.leading, isSidebarVisible ? 8 : TitleBar.trafficLightsInset)
        .padding(.trailing, 8)
        .frame(height: TitleBar.height)
        .background { Color.clear.titleBarBehavior() }
    }

    private var connectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.config.database)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(session.config.host) · \(session.connection?.serverVersion ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { session.disconnect() } label: {
                Image(systemName: "eject")
            }
            .buttonStyle(.borderless)
            .help("Disconnect")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Only the active tab is rendered; its model keeps loaded rows and editor text across switches.
    @ViewBuilder
    private var tabContents: some View {
        if let tab = session.activeTab {
            tabView(tab).id(tab.id)
        } else {
            ContentUnavailableView("No Open Tabs", systemImage: "tablecells",
                                   description: Text("Pick a table from the sidebar"))
        }
    }

    private func showValueInspector() {
        inspectorMode = .value
        showsInspector = true
    }

    @ViewBuilder
    private func tabView(_ tab: WorkspaceTab) -> some View {
        switch tab.content {
        case .query(let editor):
            QueryEditorView(model: editor, generator: session.sqlGenerator, tables: session.allRelations,
                            onShowInspector: showValueInspector)
        case .table(let browser):
            TableBrowserView(
                model: browser,
                onOpenRelation: { relation, filters in session.openTab(relation, filters: filters) },
                onShowInspector: showValueInspector
            )
        }
    }
}
