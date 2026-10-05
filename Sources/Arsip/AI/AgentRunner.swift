import Foundation

/// What an agent run reports, the same for every agent CLI.
enum AgentEvent {
    /// The session to resume for follow-up turns.
    case session(String)
    /// A streamed piece of the current reply.
    case textDelta(String)
    /// A whole reply paragraph, from agents that don't stream text.
    case message(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(id: String, output: String, isError: Bool)
    case failed(String)
}

/// Runs an agent CLI (`claude -p` or `codex exec`) with Arsip's read-only MCP server attached.
/// Used both by the chat panel (streaming) and by SQL generation (one structured answer).
@MainActor
final class AgentRunner {
    private let config: ConnectionConfig
    private var process: Process?

    init(config: ConnectionConfig) {
        self.config = config
    }

    var isRunning: Bool { process != nil }

    /// Streams events as they arrive; `onFinish` gets the exit status and anything on stderr.
    /// `tools` limits which Arsip tools the agent may call; nil allows all of them.
    func runStreaming(
        model: AgentModel,
        prompt: String,
        systemPrompt: String,
        tools: [String]? = nil,
        resume: String? = nil,
        onEvent: @escaping (AgentEvent) -> Void,
        onFinish: @escaping (Int32, String) -> Void
    ) throws {
        let parser = AgentEventParser(agent: model.agent)
        try launch(model: model, prompt: prompt, systemPrompt: systemPrompt, tools: tools, resume: resume, jsonSchema: nil) { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            parser.events(from: json).forEach(onEvent)
        } onFinish: { status, stderr in
            onFinish(status, stderr)
        }
    }

    /// One answer matching `jsonSchema`, returned as the decoded object.
    func runOnce(
        model: AgentModel,
        prompt: String,
        systemPrompt: String,
        tools: [String],
        jsonSchema: [String: Any]
    ) async throws -> [String: Any] {
        let agent = model.agent
        return try await withCheckedThrowingContinuation { continuation in
            var output = Data()
            var resumed = false
            do {
                try launch(model: model, prompt: prompt, systemPrompt: systemPrompt, tools: tools, resume: nil,
                           jsonSchema: jsonSchema, splitLines: false) { data in
                    output.append(data)
                } onFinish: { status, stderr in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(with: Self.structuredAnswer(agent: agent, output: output, status: status, stderr: stderr))
                }
            } catch {
                resumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private static func structuredAnswer(agent: AgentKind, output: Data, status: Int32, stderr: String) -> Result<[String: Any], Error> {
        let text: String?
        switch agent {
        case .claude:
            guard let result = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                return .failure(exitError(agent: agent, status: status, stderr: stderr))
            }
            if result["is_error"] as? Bool == true {
                return .failure(PGError(result["result"] as? String ?? "\(agent.displayName) reported an error"))
            }
            // `--json-schema` puts the structured answer in `result` as a JSON string.
            text = result["result"] as? String
        case .codex:
            // JSONL events; the answer is the last agent message.
            var last: String?
            for line in output.split(separator: 0x0A) {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if event["type"] as? String == "turn.failed" {
                    return .failure(PGError(AgentEventParser.message(in: event["error"]) ?? "\(agent.displayName) reported an error"))
                }
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    last = item["text"] as? String
                }
            }
            guard last != nil || status == 0 else { return .failure(exitError(agent: agent, status: status, stderr: stderr)) }
            text = last
        }
        guard let text, let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .failure(PGError("\(agent.displayName) returned an unexpected answer"))
        }
        return .success(answer)
    }

    private static func exitError(agent: AgentKind, status: Int32, stderr: String) -> PGError {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return PGError(detail.isEmpty ? "\(agent.displayName) exited with status \(status)" : String(detail.suffix(500)))
    }

    // MARK: Process plumbing

    private func launch(
        model: AgentModel,
        prompt: String,
        systemPrompt: String,
        tools: [String]?,
        resume: String?,
        jsonSchema: [String: Any]?,
        splitLines: Bool = true,
        onData: @escaping (Data) -> Void,
        onFinish: @escaping (Int32, String) -> Void
    ) throws {
        let agent = model.agent
        guard let executable = agent.executableURL else {
            throw PGError("\(agent.displayName) isn't installed. Install it and run `\(agent.command)` once in Terminal to sign in.")
        }
        let directory = AgentCLI.workingDirectory
        // Files that only live for this run; the MCP config may contain the password.
        var scratchFiles: [URL] = []
        let removeScratchFiles = { for url in scratchFiles { try? FileManager.default.removeItem(at: url) } }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        var environment = AgentCLI.environment
        do {
            switch agent {
            case .claude:
                let mcpConfigURL = directory.appendingPathComponent("mcp-\(UUID().uuidString).json")
                scratchFiles.append(mcpConfigURL)
                try writeMCPConfig(to: mcpConfigURL)
                process.arguments = try claudeArguments(model: model, mcpConfig: mcpConfigURL, systemPrompt: systemPrompt,
                                                        tools: tools, resume: resume, jsonSchema: jsonSchema)
            case .codex:
                var schemaURL: URL?
                if let jsonSchema {
                    let url = directory.appendingPathComponent("schema-\(UUID().uuidString).json")
                    scratchFiles.append(url)
                    try JSONSerialization.data(withJSONObject: jsonSchema).write(to: url)
                    schemaURL = url
                }
                // Codex passes these through to the MCP server, so the password stays off the command line.
                environment.merge(mcpEnvironment) { _, new in new }
                process.arguments = try codexArguments(model: model, systemPrompt: systemPrompt, tools: tools,
                                                       resume: resume, schema: schemaURL)
            }
        } catch {
            removeScratchFiles()
            throw error
        }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        let stderrBuffer = LockedBuffer()
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderrBuffer.append(data) }
        }

        let lines = LineSplitter { data in
            DispatchQueue.main.async { MainActor.assumeIsolated { onData(data) } }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty else {
                if splitLines {
                    lines.append(data)
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onData(data) } }
                }
                return
            }
            // EOF: wait for exit, then finish after everything read so far was handled.
            handle.readabilityHandler = nil
            DispatchQueue.global().async {
                process.waitUntilExit()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        removeScratchFiles()
                        if self?.process == process { self?.process = nil }
                        onFinish(status, stderrBuffer.text)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            removeScratchFiles()
            throw PGError("Couldn't start \(agent.displayName): \(error.localizedDescription)")
        }
        // The prompt goes over stdin so text starting with "-" can't be mistaken for a flag.
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        self.process = process
    }

    private func claudeArguments(
        model: AgentModel, mcpConfig: URL, systemPrompt: String, tools: [String]?, resume: String?, jsonSchema: [String: Any]?
    ) throws -> [String] {
        var arguments = [
            "-p",
            "--tools", "",  // no shell or file tools, only Arsip's database tools
            "--mcp-config", mcpConfig.path,
            "--strict-mcp-config",
            "--allowedTools", tools.map { $0.map { "mcp__arsip__\($0)" }.joined(separator: " ") } ?? "mcp__arsip",
            "--permission-mode", "dontAsk",
            "--setting-sources", "",
            "--append-system-prompt", systemPrompt,
        ]
        if let name = model.model { arguments += ["--model", name] }
        if let jsonSchema {
            let schema = try JSONSerialization.data(withJSONObject: jsonSchema)
            arguments += ["--output-format", "json", "--json-schema", String(decoding: schema, as: UTF8.self)]
        } else {
            arguments += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// Codex features that would give the agent anything beyond Arsip's database tools.
    private static let codexDisabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "skill_search", "browser_use", "browser_use_external",
        "in_app_browser", "computer_use", "image_generation", "view_image", "multi_agent", "goals",
    ]

    private func codexArguments(model: AgentModel, systemPrompt: String, tools: [String]?, resume: String?, schema: URL?) throws -> [String] {
        guard let executablePath = Bundle.main.executablePath else { throw PGError("Unknown executable path") }
        var arguments = ["exec"] + (resume == nil ? [] : ["resume"]) + [
            "--json",
            "--ignore-user-config",  // no user plugins, MCP servers or instructions; sign-in still applies
            "--skip-git-repo-check",
            "-c", "sandbox_mode=\"read-only\"",
            "-c", "web_search=\"disabled\"",
            "-c", "developer_instructions=" + Self.toml(systemPrompt),
            "-c", "mcp_servers.arsip.command=" + Self.toml(executablePath),
            "-c", "mcp_servers.arsip.args=" + Self.toml([MCPServer.launchArgument]),
            "-c", "mcp_servers.arsip.env_vars=" + Self.toml(mcpEnvironment.keys.sorted()),
        ]
        arguments += Self.codexDisabledFeatures.flatMap { ["--disable", $0] }
        if let tools { arguments += ["-c", "mcp_servers.arsip.enabled_tools=" + Self.toml(tools)] }
        if let name = model.model { arguments += ["-m", name] }
        if let schema { arguments += ["--output-schema", schema.path] }
        if let resume { arguments.append(resume) }
        return arguments + ["-"]  // prompt from stdin
    }

    private var mcpEnvironment: [String: String] {
        var environment = [
            MCPServer.EnvironmentKey.host: config.host,
            MCPServer.EnvironmentKey.port: String(config.port),
            MCPServer.EnvironmentKey.user: config.user,
            MCPServer.EnvironmentKey.database: config.database,
        ]
        if !config.password.isEmpty { environment[MCPServer.EnvironmentKey.password] = config.password }
        return environment
    }

    private func writeMCPConfig(to url: URL) throws {
        guard let executablePath = Bundle.main.executablePath else { throw PGError("Unknown executable path") }
        let json: [String: Any] = [
            "mcpServers": [
                "arsip": [
                    "type": "stdio",
                    "command": executablePath,
                    "args": [MCPServer.launchArgument],
                    "env": mcpEnvironment,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        // May contain the password: owner-only, and deleted when the run ends.
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PGError("Couldn't write \(url.path)")
        }
    }

    /// A TOML basic string, for codex `-c key=value` overrides.
    private static func toml(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func toml(_ strings: [String]) -> String {
        "[" + strings.map(toml).joined(separator: ", ") + "]"
    }
}

/// Turns one agent's JSON output lines into `AgentEvent`s.
@MainActor
final class AgentEventParser {
    private let agent: AgentKind
    /// Codex numbers items per turn (item_0, item_1…), so ids get a per-run prefix to stay unique.
    private let runPrefix = UUID().uuidString.prefix(8)
    private var startedTools: Set<String> = []

    init(agent: AgentKind) { self.agent = agent }

    func events(from event: [String: Any]) -> [AgentEvent] {
        switch agent {
        case .claude: claudeEvents(from: event)
        case .codex: codexEvents(from: event)
        }
    }

    private func claudeEvents(from event: [String: Any]) -> [AgentEvent] {
        switch event["type"] as? String {
        case "system":
            return (event["session_id"] as? String).map { [.session($0)] } ?? []

        case "stream_event":
            guard let inner = event["event"] as? [String: Any], inner["type"] as? String == "content_block_delta",
                  let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return [] }
            return [.textDelta(text)]

        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use", let id = block["id"] as? String else { return nil }
                let name = (block["name"] as? String ?? "").replacingOccurrences(of: "mcp__arsip__", with: "")
                return .toolUse(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
            }

        case "user":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                let text: String
                if let string = block["content"] as? String {
                    text = string
                } else {
                    let parts = block["content"] as? [[String: Any]] ?? []
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                return .toolResult(id: id, output: text, isError: block["is_error"] as? Bool ?? false)
            }

        case "result":
            var events: [AgentEvent] = (event["session_id"] as? String).map { [.session($0)] } ?? []
            if event["is_error"] as? Bool == true || (event["subtype"] as? String).map({ $0 != "success" }) == true {
                let errors = (event["errors"] as? [String])?.joined(separator: "\n")
                events.append(.failed(event["result"] as? String ?? errors ?? "\(agent.displayName) reported an error"))
            }
            return events

        default:
            return []
        }
    }

    private func codexEvents(from event: [String: Any]) -> [AgentEvent] {
        switch event["type"] as? String {
        case "thread.started":
            return (event["thread_id"] as? String).map { [.session($0)] } ?? []

        case "turn.failed":
            return [.failed(Self.message(in: event["error"]) ?? "\(agent.displayName) reported an error")]

        case let type? where type.hasPrefix("item."):
            guard let item = event["item"] as? [String: Any], let itemID = item["id"] as? String else { return [] }
            let completed = type == "item.completed"
            switch item["type"] as? String {
            case "agent_message":
                guard completed, let text = item["text"] as? String, !text.isEmpty else { return [] }
                return [.message(text)]

            case "mcp_tool_call":
                let id = "\(runPrefix)-\(itemID)"
                var events: [AgentEvent] = []
                if startedTools.insert(id).inserted {
                    events.append(.toolUse(id: id, name: item["tool"] as? String ?? "", input: item["arguments"] as? [String: Any] ?? [:]))
                }
                if completed {
                    let result = item["result"] as? [String: Any]
                    let content = result?["content"] as? [[String: Any]] ?? []
                    let error = Self.message(in: item["error"])
                    let isError = error != nil || item["status"] as? String == "failed"
                        || result?["is_error"] as? Bool == true || result?["isError"] as? Bool == true
                    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    events.append(.toolResult(id: id, output: error ?? text, isError: isError))
                }
                return events

            default:
                return []
            }

        default:
            return []
        }
    }

    /// The text of a codex error, which is either a string or `{"message": …}`.
    nonisolated static func message(in error: Any?) -> String? {
        if let string = error as? String { return string }
        return (error as? [String: Any])?["message"] as? String
    }
}

/// Splits streamed bytes into newline-terminated lines. Fed from a single pipe handler.
final class LineSplitter: @unchecked Sendable {
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

final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }

    var data: Data {
        lock.withLock { buffer }
    }

    var text: String {
        String(decoding: data, as: UTF8.self)
    }
}
