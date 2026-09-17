import Foundation
import Observation

struct ConnectionConfig: Codable, Equatable {
    var host = "localhost"
    var port = 5432
    var user = NSUserName()
    var database = NSUserName()
    /// Only what was typed this session; saved passwords live in the Keychain.
    var password = ""
    var rememberPassword = true

    private enum CodingKeys: String, CodingKey { case host, port, user, database, rememberPassword }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        user = try container.decode(String.self, forKey: .user)
        database = try container.decode(String.self, forKey: .database)
        rememberPassword = try container.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? true
    }

    /// Identifies a server + login + database, for the Keychain and saved workspaces.
    var account: String { "\(user)@\(host):\(port)/\(database)" }

    private static let defaultsKey = "lastConnection"

    static func loadLast() -> ConnectionConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(ConnectionConfig.self, from: data)
        else { return ConnectionConfig() }
        return config
    }

    func saveAsLast() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum RelationKind: String, Codable {
    case table, view, materializedView, foreignTable

    init?(relkind: String) {
        switch relkind {
        case "r", "p": self = .table
        case "v": self = .view
        case "m": self = .materializedView
        case "f": self = .foreignTable
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .table: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        case .foreignTable: "globe"
        }
    }
}

struct RelationRef: Hashable, Identifiable {
    let schema: String
    let name: String
    let kind: RelationKind

    var id: String { "\(schema).\(name)" }
    var qualifiedName: String { "\(quoteIdent(schema)).\(quoteIdent(name))" }
}

struct SchemaGroup: Identifiable {
    let name: String
    var relations: [RelationRef]
    var id: String { name }
}

enum SidebarItem: Hashable {
    case query
    case relation(RelationRef)
}

/// What gets restored on the next connect: open tabs and which one was active.
struct WorkspaceSnapshot: Codable {
    enum Tab: Codable {
        case query(text: String)
        case table(schema: String, name: String, kind: RelationKind, filters: [ColumnFilter], sort: GridSort?)
    }

    var tabs: [Tab]
    var activeIndex: Int?
}

struct WorkspaceTab: Identifiable {
    enum Content {
        case query(QueryEditorModel)
        case table(TableBrowserModel)
    }

    let id = UUID()
    let content: Content

    @MainActor var title: String {
        switch content {
        case .query: "SQL Query"
        case .table(let browser): browser.title
        }
    }

    var symbol: String {
        switch content {
        case .query: "terminal"
        case .table(let browser): browser.relation.kind.symbol
        }
    }

    var sidebarItem: SidebarItem {
        switch content {
        case .query: .query
        case .table(let browser): .relation(browser.relation)
        }
    }
}

/// One window = one session = one connection.
@MainActor @Observable
final class SessionModel {
    private static let reconnectKey = "reconnectOnLaunch"
    /// Only the first window of a launch reconnects automatically.
    private static var didAttemptLaunchReconnect = false

    var config = ConnectionConfig.loadLast()
    private(set) var connection: PGConnection?
    var isConnecting = false
    var connectError: String?

    var schemas: [SchemaGroup] = []
    var sidebarFilter = ""
    private(set) var tabs: [WorkspaceTab] = []
    private(set) var activeTabID: UUID?
    private(set) var assistant: AssistantModel?
    private(set) var sqlGenerator: SQLGenerator?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var isConnected: Bool { connection != nil }

    var allRelations: [RelationRef] { schemas.flatMap(\.relations) }

    var filteredSchemas: [SchemaGroup] {
        let filter = sidebarFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return schemas }
        return schemas.compactMap { group in
            var group = group
            group.relations = group.relations.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            return group.relations.isEmpty ? nil : group
        }
    }

    func reconnectOnLaunchIfNeeded() async {
        guard !Self.didAttemptLaunchReconnect else { return }
        Self.didAttemptLaunchReconnect = true
        if UserDefaults.standard.bool(forKey: Self.reconnectKey) { await connect() }
    }

    func connect() async {
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }

        var attempt = config
        if attempt.password.isEmpty, attempt.rememberPassword {
            attempt.password = Keychain.password(account: attempt.account) ?? ""
        }
        do {
            let connection = try await PGConnection.connect(attempt)
            if config.rememberPassword {
                if !config.password.isEmpty { Keychain.setPassword(config.password, account: config.account) }
            } else {
                Keychain.deletePassword(account: config.account)
            }
            config.password = ""
            config.saveAsLast()
            UserDefaults.standard.set(true, forKey: Self.reconnectKey)

            self.connection = connection
            let assistant = AssistantModel(config: attempt, serverVersion: connection.serverVersion)
            assistant.contextProvider = { [weak self] in self?.assistantContext }
            assistant.onAction = { [weak self] action in
                Task { await self?.perform(action) }
            }
            assistant.changeRunner = { [weak self] sql, commit in
                await self?.runProposedChange(sql, commit: commit) ?? ExecutionOutcome(error: "Not connected")
            }
            self.assistant = assistant
            sqlGenerator = SQLGenerator(config: attempt)
            restoreWorkspace()
            await refreshCatalog()
        } catch {
            connectError = error.localizedDescription
        }
    }

    func disconnect() {
        saveWorkspace()
        UserDefaults.standard.set(false, forKey: Self.reconnectKey)
        assistant?.stop()
        assistant = nil
        sqlGenerator?.cancel()
        sqlGenerator = nil
        tabs = []
        activeTabID = nil
        connection = nil
        schemas = []
    }

    /// Dry runs roll back and give up after 30s; applied changes refresh what's on screen.
    private func runProposedChange(_ sql: String, commit: Bool) async -> ExecutionOutcome {
        guard let connection else { return ExecutionOutcome(error: "Not connected") }
        let keyword = MCPServer.firstKeyword(sql)
        guard !["BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE"].contains(keyword) else {
            return ExecutionOutcome(error: "Transaction commands can't be applied from a proposal")
        }
        let outcome = await connection.executeInTransaction(sql, commit: commit, statementTimeout: commit ? nil : "30s")
        if commit, outcome.error == nil {
            await refresh()
        }
        return outcome
    }

    private func perform(_ action: AssistantAction) async {
        switch action {
        case .openQuery(let sql):
            openQueryTab(text: sql)
        case .openTable(let name, let filters):
            if relation(named: name) == nil { await refreshCatalog() }  // may have been created since
            if let relation = relation(named: name) { openTab(relation, filters: filters) }
        }
    }

    /// Resolves "orders", "public.orders" or "\"Public\".\"Orders\"" like search_path would, preferring public.
    private func relation(named name: String) -> RelationRef? {
        let parts = name.split(separator: ".", maxSplits: 1).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        let all = schemas.flatMap(\.relations)
        if parts.count == 2 {
            return all.first { $0.schema == parts[0] && $0.name == parts[1] }
        }
        return all.first { $0.schema == "public" && $0.name == parts[0] } ?? all.first { $0.name == parts[0] }
    }

    /// What the assistant is told the user is looking at.
    private var assistantContext: String? {
        switch activeTab?.content {
        case .table(let browser):
            var context = "The user has the \(browser.relation.kind.rawValue) \(browser.relation.schema).\(browser.relation.name) open"
            if !browser.filters.isEmpty { context += ", filtered by \(browser.filterDescription)" }
            return context + "."
        case .query(let editor):
            let sql = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty else { return "The user has an empty SQL query tab open." }
            return "The user has a SQL query tab open with:\n```sql\n\(String(sql.prefix(4000)))\n```"
        case nil:
            return nil
        }
    }

    /// ⌘R: reload the table list and the active table tab.
    func refresh() async {
        await refreshCatalog()
        if case .table(let browser) = activeTab?.content {
            await browser.reload()
        }
    }

    // MARK: Tabs

    var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID }
    }

    var sidebarSelection: SidebarItem? { activeTab?.sidebarItem }

    /// Sidebar clicks reuse the active table tab (like Postico); the query tab is never replaced.
    func sidebarSelected(_ item: SidebarItem?) {
        switch item {
        case nil:
            return
        case .query:
            if let tab = tabs.first(where: { $0.sidebarItem == .query }) {
                activate(tab.id)
            } else {
                openQueryTab(restoreSavedText: true)
            }
        case .relation(let relation):
            guard activeTab?.sidebarItem != item, let tab = makeTableTab(relation) else { return }
            if case .table = activeTab?.content, let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs[index] = tab
                activate(tab.id)
            } else if let existing = tabs.first(where: { $0.sidebarItem == item }) {
                activate(existing.id)
            } else {
                insertTab(tab)
            }
        }
    }

    func activate(_ id: UUID) {
        activeTabID = id
        scheduleSave()
    }

    func openTab(_ relation: RelationRef, filters: [ColumnFilter] = []) {
        if let tab = makeTableTab(relation, filters: filters) { insertTab(tab) }
    }

    func openQueryTab(restoreSavedText: Bool = false) {
        insertTab(makeQueryTab(text: nil, restoreSavedText: restoreSavedText))
    }

    func openQueryTab(text: String) {
        insertTab(makeQueryTab(text: text))
    }

    private func makeTableTab(_ relation: RelationRef, filters: [ColumnFilter] = [], sort: GridSort? = nil) -> WorkspaceTab? {
        guard let connection else { return nil }
        let browser = TableBrowserModel(relation: relation, connection: connection, filters: filters, sort: sort)
        browser.onStateChange = { [weak self] in self?.scheduleSave() }
        return WorkspaceTab(content: .table(browser))
    }

    private func makeQueryTab(text: String?, restoreSavedText: Bool = false) -> WorkspaceTab {
        let editor = QueryEditorModel(restoreSavedText: restoreSavedText)
        if let text { editor.text = text }
        editor.connection = connection
        editor.onTextChange = { [weak self] in self?.scheduleSave() }
        return WorkspaceTab(content: .query(editor))
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if case .query(let editor) = tabs[index].content { editor.cancel() }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        scheduleSave()
    }

    private func insertTab(_ tab: WorkspaceTab) {
        let index = tabs.firstIndex(where: { $0.id == activeTabID }).map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
        activate(tab.id)
    }

    // MARK: Workspace persistence

    private var workspaceKey: String { "workspace.\(config.account)" }

    /// Debounced so typing in the editor doesn't write on every keystroke. Saving often matters:
    /// rebuilds kill the app without a normal quit.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveWorkspace()
        }
    }

    private func saveWorkspace() {
        guard isConnected else { return }
        let snapshot = WorkspaceSnapshot(
            tabs: tabs.map { tab in
                switch tab.content {
                case .query(let editor):
                    .query(text: editor.text)
                case .table(let browser):
                    .table(schema: browser.relation.schema, name: browser.relation.name, kind: browser.relation.kind,
                           filters: browser.filters, sort: browser.sort)
                }
            },
            activeIndex: tabs.firstIndex { $0.id == activeTabID }
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: workspaceKey)
        }
    }

    private func restoreWorkspace() {
        tabs = []
        activeTabID = nil
        guard let data = UserDefaults.standard.data(forKey: workspaceKey),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
              !snapshot.tabs.isEmpty
        else {
            openQueryTab(restoreSavedText: true)
            return
        }
        tabs = snapshot.tabs.compactMap { saved in
            switch saved {
            case .query(let text):
                makeQueryTab(text: text)
            case .table(let schema, let name, let kind, let filters, let sort):
                makeTableTab(RelationRef(schema: schema, name: name, kind: kind), filters: filters, sort: sort)
            }
        }
        let index = min(max(snapshot.activeIndex ?? 0, 0), tabs.count - 1)
        activeTabID = tabs.isEmpty ? nil : tabs[index].id
    }

    func refreshCatalog() async {
        guard let connection else { return }
        let sql = """
            SELECT n.nspname, c.relname, c.relkind
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND NOT c.relispartition
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_toast%'
              AND n.nspname NOT LIKE 'pg_temp%'
            ORDER BY n.nspname <> 'public', n.nspname, c.relname
            """
        let outcome = await connection.execute(sql)
        guard let result = outcome.results.first?.rows else { return }

        var groups: [SchemaGroup] = []
        for row in 0..<result.rowCount {
            guard let schema = result.value(row: row, column: 0),
                  let name = result.value(row: row, column: 1),
                  let kind = result.value(row: row, column: 2).flatMap(RelationKind.init(relkind:))
            else { continue }
            let ref = RelationRef(schema: schema, name: name, kind: kind)
            if groups.last?.name == schema {
                groups[groups.count - 1].relations.append(ref)
            } else {
                groups.append(SchemaGroup(name: schema, relations: [ref]))
            }
        }
        schemas = groups
    }
}
