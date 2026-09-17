import Foundation
import Observation

/// Chat with Claude Code about the connected database. Each turn runs `claude -p` with
/// Arsip's read-only MCP server; follow-up turns resume the same Claude session.
@MainActor @Observable
final class AssistantModel {
    struct ToolCall: Identifiable {
        let id: String
        let name: String
        /// The SQL or table name the tool was called with.
        let detail: String
        var output: String?
        var isError = false

        var title: String {
            switch name {
            case "list_tables": "Listed tables"
            case "describe_table": "Described \(detail)"
            case "run_query": "Ran query"
            case "explain_query": "Explained query"
            default: name
            }
        }

        var symbol: String {
            switch name {
            case "list_tables": "list.bullet"
            case "describe_table": "tablecells"
            case "run_query": "play"
            case "explain_query": "gauge.with.dots.needle.33percent"
            default: "wrench"
            }
        }
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
    var draft = ""

    let databaseName: String
    /// Describes what the user is looking at (open table, query text); sent with each prompt.
    @ObservationIgnored var contextProvider: (() -> String?)?

    @ObservationIgnored private let config: ConnectionConfig
    @ObservationIgnored private let serverVersion: String
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var runID = UUID()

    init(config: ConnectionConfig, serverVersion: String) {
        self.config = config
        self.serverVersion = serverVersion
        databaseName = config.database
    }

    var isClaudeInstalled: Bool { ClaudeCLI.executableURL != nil }

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
        process?.terminate()
        process = nil
        isRunning = false
        dropEmptyReply()
    }

    func newConversation() {
        stop()
        messages = []
        sessionID = nil
        error = nil
        revision += 1
    }

    // MARK: Running claude

    private func start(_ prompt: String) {
        guard let executable = ClaudeCLI.executableURL else {
            fail("Claude Code isn't installed. Install it from claude.com/claude-code and run `claude` once to sign in.")
            return
        }
        let directory = ClaudeCLI.workingDirectory
        let mcpConfigURL = directory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        do {
            try writeMCPConfig(to: mcpConfigURL)
        } catch {
            fail("Couldn't prepare the database tools: \(error.localizedDescription)")
            return
        }

        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--tools", "",  // no shell or file tools, only Arsip's database tools
            "--mcp-config", mcpConfigURL.path,
            "--strict-mcp-config",
            "--allowedTools", "mcp__arsip",
            "--permission-mode", "dontAsk",
            "--setting-sources", "",
            "--append-system-prompt", systemPrompt,
        ]
        if let sessionID { arguments += ["--resume", sessionID] }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ClaudeCLI.environment

        let input = Pipe(), output = Pipe(), errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        let runID = UUID()
        self.runID = runID
        let stderrBuffer = LockedBuffer()
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderrBuffer.append(data) }
        }

        let lines = LineSplitter { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(line, runID: runID) }
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty else {
                lines.append(data)
                return
            }
            // EOF: wait for exit, then finish after all queued lines were handled.
            handle.readabilityHandler = nil
            DispatchQueue.global().async {
                process.waitUntilExit()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        try? FileManager.default.removeItem(at: mcpConfigURL)
                        self?.finish(runID: runID, status: status, stderr: stderrBuffer.text)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: mcpConfigURL)
            fail("Couldn't start Claude Code: \(error.localizedDescription)")
            return
        }
        // The prompt goes over stdin so text starting with "-" can't be mistaken for a flag.
        input.fileHandleForWriting.write(Data(promptWithContext(prompt).utf8))
        try? input.fileHandleForWriting.close()

        self.process = process
        isRunning = true
    }

    private func promptWithContext(_ prompt: String) -> String {
        guard let context = contextProvider?(), !context.isEmpty else { return prompt }
        return "<arsip_context>\n\(context)\n</arsip_context>\n\n\(prompt)"
    }

    private var systemPrompt: String {
        """
        You are the database assistant inside Arsip, a native macOS PostgreSQL client.
        Connected database: \(config.database) on \(config.host):\(config.port) as \(config.user) (\(serverVersion)).

        - Use the arsip tools (list_tables, describe_table, run_query, explain_query) to look at the real schema \
        and data before answering. Don't guess column names.
        - Your access is read-only. If the user wants to change data or schema, write the SQL for them to review \
        and run themselves, and say what it will affect.
        - Be concise. Put SQL in ```sql code blocks (the user can open them in a query tab). \
        Use small markdown tables for tabular results.
        - <arsip_context> describes what the user currently has open in Arsip.
        """
    }

    private func writeMCPConfig(to url: URL) throws {
        guard let executablePath = Bundle.main.executablePath else { throw PGError("Unknown executable path") }
        var environment = [
            MCPServer.EnvironmentKey.host: config.host,
            MCPServer.EnvironmentKey.port: String(config.port),
            MCPServer.EnvironmentKey.user: config.user,
            MCPServer.EnvironmentKey.database: config.database,
        ]
        if !config.password.isEmpty { environment[MCPServer.EnvironmentKey.password] = config.password }

        let json: [String: Any] = [
            "mcpServers": [
                "arsip": [
                    "type": "stdio",
                    "command": executablePath,
                    "args": [MCPServer.launchArgument],
                    "env": environment,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        // May contain the password: owner-only, and deleted when the run ends.
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PGError("Couldn't write \(url.path)")
        }
    }

    // MARK: Stream events

    private func handle(_ line: Data, runID: UUID) {
        guard runID == self.runID,
              let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "system":
            if let id = event["session_id"] as? String { sessionID = id }

        case "stream_event":
            guard let inner = event["event"] as? [String: Any], inner["type"] as? String == "content_block_delta",
                  let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return }
            appendText(text)

        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, !containsTool(id) else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let name = (block["name"] as? String ?? "").replacingOccurrences(of: "mcp__arsip__", with: "")
                let detail = input["sql"] as? String ?? input["table"] as? String ?? input["schema"] as? String ?? ""
                appendBlock(.tool(ToolCall(id: id, name: name, detail: detail)))
            }

        case "user":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let text: String
                if let string = block["content"] as? String {
                    text = string
                } else {
                    let parts = block["content"] as? [[String: Any]] ?? []
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                updateTool(id, output: text, isError: block["is_error"] as? Bool ?? false)
            }

        case "result":
            if let id = event["session_id"] as? String { sessionID = id }
            if event["is_error"] as? Bool == true || (event["subtype"] as? String).map({ $0 != "success" }) == true {
                let errors = (event["errors"] as? [String])?.joined(separator: "\n")
                error = event["result"] as? String ?? errors ?? "Claude Code reported an error"
            }

        default:
            break
        }
    }

    private func finish(runID: UUID, status: Int32, stderr: String) {
        guard runID == self.runID else { return }
        process = nil
        isRunning = false
        if status != 0, error == nil {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            error = detail.isEmpty ? "Claude Code exited with status \(status)" : String(detail.suffix(1000))
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

    private func updateTool(_ id: String, output: String, isError: Bool) {
        guard !messages.isEmpty else { return }
        let index = messages.count - 1
        for (blockIndex, block) in messages[index].blocks.enumerated() {
            if case .tool(var call) = block, call.id == id {
                call.output = output
                call.isError = isError
                messages[index].blocks[blockIndex] = .tool(call)
                revision += 1
                return
            }
        }
    }

    private func dropEmptyReply() {
        if let last = messages.last, last.role == .assistant, last.blocks.isEmpty {
            messages.removeLast()
        }
    }
}

/// Finding and running the `claude` CLI from a GUI app, which doesn't get the user's shell PATH.
enum ClaudeCLI {
    static let executableURL: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to the login shell's PATH.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }()

    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }()

    /// An empty directory, so no project CLAUDE.md or settings get picked up.
    static var workingDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arsip/Assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Splits streamed bytes into newline-terminated lines. Fed from a single pipe handler.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let onLine: (Data) -> Void

    init(onLine: @escaping (Data) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine(Data(line)) }
        }
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
