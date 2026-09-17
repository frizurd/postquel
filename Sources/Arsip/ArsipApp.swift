import AppKit
import SwiftUI

@main
struct ArsipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Arsip") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified)
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
        if session.isConnected {
            BrowserView(session: session)
        } else {
            ConnectView(session: session)
                .task { await session.reconnectOnLaunchIfNeeded() }
        }
    }
}

struct BrowserView: View {
    @Bindable var session: SessionModel
    @State private var detailWidth: CGFloat = 800

    var body: some View {
        NavigationSplitView {
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
        } detail: {
            tabContents
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
                .toolbar(removing: .title)
                .toolbar {
                    // Tabs live in the title bar instead of a window title.
                    ToolbarItem(placement: .navigation) {
                        // Toolbar items don't stretch on their own; size the strip to the detail column
                        // (minus the toolbar's own edge insets) so the buttons sit at the trailing edge.
                        TabStrip(session: session)
                            .frame(width: max(300, detailWidth - 22))
                    }
                }
        }
        .navigationTitle(session.config.database)
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

    @ViewBuilder
    private func tabView(_ tab: WorkspaceTab) -> some View {
        switch tab.content {
        case .query(let editor):
            QueryEditorView(model: editor)
        case .table(let browser):
            TableBrowserView(model: browser) { relation, filters in
                session.openTab(relation, filters: filters)
            }
        }
    }
}
