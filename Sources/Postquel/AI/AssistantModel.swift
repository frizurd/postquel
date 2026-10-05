import Foundation
import Observation

enum AssistantAction {
    case openTable(name: String, filters: [ColumnFilter])
    case openQuery(sql: String)
}

/// Chat with an agent (Claude Code, Codex, Cursor) about the connected database. Each turn runs the agent
/// CLI with Postquel's read-only MCP server; follow-up turns resume the same agent session.
@MainActor @Observable
final class AssistantModel {
    struct ToolCall: Identifiable {
        let id: String
        let name: String
        /// The SQL or table name the tool was called with.
        let detail: String
        /// For propose_change: the one-line description of the change.
        var summary: String?
        var output: String?
        var isError = false

        var title: String {
            switch name {
            case "list_tables": "Listed tables"
            case "describe_table": "Described \(detail)"
            case "run_query": "Ran query"
            case "explain_query": "Explained query"
            case "open_table": "Opened \(detail)"
            case "open_query_tab": "Opened query tab"
            case "propose_change": "Proposed change"
            default: name
            }
        }

        var symbol: String {
            switch name {
            case "list_tables": "list.bullet"
            case "describe_table": "tablecells"
            case "run_query": "play"
            case "explain_query": "gauge.with.dots.needle.33percent"
            case "open_table", "open_query_tab": "arrow.up.right.square"
            case "propose_change": "pencil.and.list.clipboard"
            default: "wrench"
            }
        }

        var showsSQL: Bool {
            ["run_query", "explain_query", "open_query_tab", "propose_change"].contains(name)
        }

        /// Statement keyword and planner estimate reported by the server for a proposal.
        var proposalStatement: String? { outputLine(after: "Statement: ") }
        var proposalEstimate: String? { outputLine(after: "Planner estimate: ") }

        private func outputLine(after prefix: String) -> String? {
            output?.components(separatedBy: "\n").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
    }

    enum ProposalState: Equatable {
        case pending
        case running(apply: Bool)
        case dryRan(String)
        case applied(String)
        case failed(String)
        case dismissed
    }

    enum Block: Identifiable {
        case text(id: UUID, String)
        case tool(ToolCall)

        var id: String {
            switch self {
            case .text(let id, _): id.uuidString
            case .tool(let call): call.id
            }
        }
    }

    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var blocks: [Block]
    }

    private(set) var messages: [Message] = []
    private(set) var isRunning = false
    private(set) var error: String?
    /// Bumped on every streamed change, so the transcript can follow along.
    private(set) var revision = 0
    private(set) var proposalStates: [String: ProposalState] = [:]
    var draft = ""

    let databaseName: String
    /// Describes what the user is looking at (open table, query text); sent with each prompt.
    @ObservationIgnored var contextProvider: (() -> String?)?
    /// Performs `open_table` / `open_query_tab` in the window once the tool call succeeded.
    @ObservationIgnored var onAction: ((AssistantAction) -> Void)?
    @ObservationIgnored private var toolInputs: [String: [String: Any]] = [:]
    /// Runs a proposed statement in a transaction on the user's connection; `commit: false` rolls back.
    @ObservationIgnored var changeRunner: ((_ sql: String, _ commit: Bool) async -> ExecutionOutcome)?
    /// What happened to proposals since the last prompt, told to the agent on the next turn.
    @ObservationIgnored private var notes: [String] = []

    @ObservationIgnored private let config: ConnectionConfig
    @ObservationIgnored private let serverVersion: String
    @ObservationIgnored private let runner: AgentRunner
    @ObservationIgnored private var sessionID: String?
    /// The agent `sessionID` belongs to; switching agents starts a fresh session.
    @ObservationIgnored private var sessionAgent: AgentKind?
    /// The agent running the current turn, for error messages.
    @ObservationIgnored private var runningAgent: AgentKind = .claude
    @ObservationIgnored private var runID = UUID()

    init(config: ConnectionConfig, serverVersion: String) {
        self.config = config
        self.serverVersion = serverVersion
        runner = AgentRunner(config: config)
        databaseName = config.database
    }

    func send(_ text: String? = nil) {
        let prompt = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        draft = ""
        error = nil
        messages.append(Message(role: .user, blocks: [.text(id: UUID(), prompt)]))
        messages.append(Message(role: .assistant, blocks: []))
        revision += 1
        start(prompt)
    }

    func stop() {
        runID = UUID()  // ignore anything the stopped process still prints
        runner.stop()
        isRunning = false
        dropEmptyReply()
    }

    func newConversation() {
        stop()
        messages = []
        proposalStates = [:]
        notes = []
        sessionID = nil
        sessionAgent = nil
        error = nil
        revision += 1
    }

    // MARK: Running the agent

    private func start(_ prompt: String) {
        let runID = UUID()
        self.runID = runID
        let model = AgentCatalog.shared.selection
        if sessionAgent != model.agent {
            sessionID = nil
            sessionAgent = model.agent
        }
        runningAgent = model.agent
        do {
            try runner.runStreaming(
                model: model,
                prompt: promptWithContext(prompt),
                systemPrompt: systemPrompt,
                resume: sessionID,
                onEvent: { [weak self] event in self?.handle(event, runID: runID) },
                onFinish: { [weak self] status, stderr in self?.finish(runID: runID, status: status, stderr: stderr) }
            )
        } catch {
            fail(error.localizedDescription)
            return
        }
        isRunning = true
    }

    private func promptWithContext(_ prompt: String) -> String {
        let context = ([contextProvider?()].compactMap { $0 } + notes).filter { !$0.isEmpty }
        notes = []
        guard !context.isEmpty else { return prompt }
        return "<postquel_context>\n\(context.joined(separator: "\n"))\n</postquel_context>\n\n\(prompt)"
    }

    // MARK: Proposed changes

    func dryRun(_ call: ToolCall) {
        run(call, apply: false)
    }

    func apply(_ call: ToolCall) {
        run(call, apply: true)
    }

    func dismiss(_ call: ToolCall) {
        proposalStates[call.id] = .dismissed
        notes.append("The user dismissed your proposed change: \(call.summary ?? call.detail)")
    }

    private func run(_ call: ToolCall, apply: Bool) {
        guard let changeRunner, proposalStates[call.id].map(Self.canRun) ?? true else { return }
        proposalStates[call.id] = .running(apply: apply)
        Task {
            let outcome = await changeRunner(call.detail, apply)
            if let error = outcome.error {
                proposalStates[call.id] = .failed(error)
                if apply { notes.append("Applying your proposed change failed: \(error)") }
                return
            }
            let result = outcome.results.last
            if apply {
                proposalStates[call.id] = .applied(result?.status ?? "Done")
                notes.append("The user applied your proposed change (\(call.summary ?? call.detail)): \(result?.status ?? "done")")
            } else if let rows = result?.affectedRows,
                      ["INSERT", "UPDATE", "DELETE", "MERGE"].contains(where: { result?.status.hasPrefix($0) == true }) {
                proposalStates[call.id] = .dryRan("Would affect \(rows.formatted()) \(rows == 1 ? "row" : "rows")")
            } else {
                proposalStates[call.id] = .dryRan("Ran without errors (\(result?.status ?? "OK")), then rolled back")
            }
        }
    }

    private static func canRun(_ state: ProposalState) -> Bool {
        switch state {
        case .pending, .dryRan, .failed: true
        case .running, .applied, .dismissed: false
        }
    }

    private var systemPrompt: String {
        """
        You are the database assistant inside Postquel, a native macOS PostgreSQL client.
        Connected database: \(config.database) on \(config.host):\(config.port) as \(config.user) (\(serverVersion)).

        - Use the postquel tools (list_tables, describe_table, run_query, explain_query) to look at the real schema \
        and data before answering. Don't guess column names.
        - Your access is read-only. If the user wants to change data or schema, write the SQL for them to review \
        and run themselves, and say what it will affect.
        - When the user wants to see rows, open them with open_table (use filters for specific rows) instead of \
        pasting long results. Use open_query_tab for longer read queries.
        - For any data or schema change, call propose_change once per statement with a short summary. The user \
        reviews it as a card, can dry-run it for the exact row count, and applies it themselves. Mention risks \
        (locks on big tables, irreversible deletes) briefly.
        - Be concise. Put short SQL in ```sql code blocks (the user can open them in a query tab). \
        Use small markdown tables for small results.
        - <postquel_context> describes what the user currently has open in Postquel.
        """
    }

    // MARK: Stream events

    private func handle(_ event: AgentEvent, runID: UUID) {
        guard runID == self.runID else { return }

        switch event {
        case .session(let id):
            sessionID = id

        case .textDelta(let text):
            appendText(text)

        case .message(let text):
            appendText(Self.continuesText(messages.last) ? "\n\n" + text : text)

        case .toolUse(let id, let name, let input):
            guard !containsTool(id) else { return }
            toolInputs[id] = input
            if name == "propose_change" { proposalStates[id] = .pending }
            let detail = input["sql"] as? String ?? input["table"] as? String ?? input["schema"] as? String ?? ""
            appendBlock(.tool(ToolCall(id: id, name: name, detail: detail, summary: input["summary"] as? String)))

        case .toolResult(let id, let output, let isError):
            if updateTool(id, output: output, isError: isError), !isError {
                performAction(for: id)
            }

        case .failed(let message):
            error = message
        }
    }

    private static func continuesText(_ message: Message?) -> Bool {
        guard case .text? = message?.blocks.last else { return false }
        return true
    }

    private func finish(runID: UUID, status: Int32, stderr: String) {
        guard runID == self.runID else { return }
        isRunning = false
        if status != 0, error == nil {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            error = detail.isEmpty ? "\(runningAgent.displayName) exited with status \(status)" : String(detail.suffix(1000))
        }
        dropEmptyReply()
        revision += 1
    }

    private func fail(_ message: String) {
        error = message
        dropEmptyReply()
    }

    // MARK: Transcript updates

    private func appendText(_ text: String) {
        guard var message = messages.last, message.role == .assistant else { return }
        if case .text(let id, let existing) = message.blocks.last {
            message.blocks[message.blocks.count - 1] = .text(id: id, existing + text)
        } else {
            message.blocks.append(.text(id: UUID(), text))
        }
        messages[messages.count - 1] = message
        revision += 1
    }

    private func appendBlock(_ block: Block) {
        guard !messages.isEmpty, messages[messages.count - 1].role == .assistant else { return }
        messages[messages.count - 1].blocks.append(block)
        revision += 1
    }

    private func containsTool(_ id: String) -> Bool {
        messages.last?.blocks.contains { $0.id == id } ?? false
    }

    private func performAction(for toolID: String) {
        guard let input = toolInputs.removeValue(forKey: toolID),
              case .tool(let call)? = messages.last?.blocks.first(where: { $0.id == toolID })
        else { return }
        switch call.name {
        case "open_table":
            guard let table = input["table"] as? String else { return }
            let filters = (input["filters"] as? [[String: Any]] ?? []).compactMap { filter -> ColumnFilter? in
                guard let column = filter["column"] as? String, let value = filter["value"] else { return nil }
                return ColumnFilter(column: column, value: value as? String ?? "\(value)")
            }
            onAction?(.openTable(name: table, filters: filters))
        case "open_query_tab":
            if let sql = input["sql"] as? String { onAction?(.openQuery(sql: sql)) }
        default:
            break
        }
    }

    /// Returns true the first time a result arrives for this call.
    @discardableResult
    private func updateTool(_ id: String, output: String, isError: Bool) -> Bool {
        guard !messages.isEmpty else { return false }
        let index = messages.count - 1
        for (blockIndex, block) in messages[index].blocks.enumerated() {
            if case .tool(var call) = block, call.id == id {
                guard call.output == nil else { return false }
                call.output = output
                call.isError = isError
                messages[index].blocks[blockIndex] = .tool(call)
                revision += 1
                return true
            }
        }
        return false
    }

    private func dropEmptyReply() {
        if let last = messages.last, last.role == .assistant, last.blocks.isEmpty {
            messages.removeLast()
        }
    }
}
