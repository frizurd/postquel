import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // Agent CLIs (Claude Code, Codex, Cursor) launch this same binary as a stdio MCP server.
        if CommandLine.arguments.dropFirst().first == MCPServer.launchArgument {
            MCPServer.runFromEnvironment()
        } else {
            LegacyMigration.migrateSettings()
            PostquelApp.main()
        }
    }
}

struct PostquelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Postquel") {
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
        AgentCLI.removeStaleWorkspaces()
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
    @State private var renamingQuery: SavedQuery?
    /// Tabs whose views are kept built, most recently used first.
    @State private var builtTabIDs: [UUID] = []

    private var isSidebarVisible: Bool { columnVisibility != .detailOnly }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(get: { session.sidebarSelection }, set: { session.sidebarSelected($0) })) {
                Section {
                    sidebarRow("New Query", symbol: "terminal").tag(SidebarItem.query)
                    ForEach(Array(session.savedQueries.enumerated()), id: \.element.id) { index, query in
                        sidebarRow(query.name, number: index + 1)
                            .tag(SidebarItem.savedQuery(query.id))
                            .contextMenu {
                                Button("Rename…") { renamingQuery = query }
                                Button("Delete", role: .destructive) { session.deleteQuery(query.id) }
                            }
                    }
                } header: {
                    Text("Queries").sectionLabel()
                }
                ForEach(session.filteredSchemas) { group in
                    Section {
                        ForEach(group.relations) { relation in
                            sidebarRow(relation.name, symbol: relation.kind.symbol)
                                .tag(SidebarItem.relation(relation))
                                .contextMenu {
                                    Button("Open in New Tab") { session.openTab(relation) }
                                }
                        }
                    } header: {
                        Text(group.name).sectionLabel()
                    }
                }
            }
            .listStyle(.sidebar)
            .floatingBar(edge: .bottom) { ConnectionFooter(session: session) }
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
        .sheet(item: $renamingQuery) { query in
            RenameQuerySheet(name: query.name) { session.renameQuery(query.id, to: $0) }
        }
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
            .padding(2)
            .glassOnly(Capsule())
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

    /// Saved queries are numbered instead of carrying an icon.
    private func sidebarRow(_ title: String, number: Int) -> some View {
        HStack(spacing: 9) {
            Text("\(number).")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 17, alignment: .trailing)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func sidebarRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(width: 17, alignment: .center)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    /// The most recently used tabs stay built while hidden, so switching between them is instant
    /// instead of rebuilding the grid and editor. Older ones are rebuilt from their models on return.
    @ViewBuilder
    private var tabContents: some View {
        if session.activeTab == nil {
            ContentUnavailableView("No Open Tabs", systemImage: "tablecells",
                                   description: Text("Pick a table from the sidebar"))
        } else {
            ZStack {
                ForEach(session.tabs.filter { builtTabIDs.contains($0.id) || $0.id == session.activeTabID }) { tab in
                    tabView(tab)
                        .inactive(tab.id != session.activeTabID)
                }
            }
            .onAppear { noteActiveTab() }
            .onChange(of: session.activeTabID) { noteActiveTab() }
        }
    }

    private static let builtTabLimit = 6

    /// Moves the active tab to the front of the built list and lets the oldest ones go. Keyboard focus
    /// is dropped too, so typing can't land in an editor that's now hidden.
    private func noteActiveTab() {
        guard let id = session.activeTabID else { return }
        let open = Set(session.tabs.map(\.id))
        builtTabIDs = Array(([id] + builtTabIDs.filter { $0 != id && open.contains($0) }).prefix(Self.builtTabLimit))
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
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
            QueryEditorView(
                model: editor,
                generator: session.sqlGenerator,
                tables: session.allRelations,
                onShowInspector: showValueInspector,
                onAskAssistant: { prompt in
                    inspectorMode = .assistant
                    showsInspector = true
                    session.assistant?.send(prompt)
                },
                onSaveQuery: { name in session.saveQuery(named: name, from: editor) }
            )
        case .table(let browser):
            TableBrowserView(
                model: browser,
                onOpenRelation: { relation, filters in session.openTab(relation, filters: filters) },
                onShowInspector: showValueInspector,
                onOpenQuery: { session.openQueryTab(text: $0) }
            )
        }
    }
}
