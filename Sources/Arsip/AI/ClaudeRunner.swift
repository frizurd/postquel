import Foundation

/// Runs `claude -p` with Arsip's read-only MCP server attached. Used both by the chat panel
/// (streaming) and by SQL generation (one structured answer).
@MainActor
final class ClaudeRunner {
    private let config: ConnectionConfig
    private var process: Process?

    init(config: ConnectionConfig) {
        self.config = config
    }

    var isRunning: Bool { process != nil }

    /// Streams events as they arrive; `onFinish` gets the exit status and anything on stderr.
    func runStreaming(
        prompt: String,
        systemPrompt: String,
        allowedTools: String = "mcp__arsip",
        resume: String? = nil,
        onEvent: @escaping ([String: Any]) -> Void,
        onFinish: @escaping (Int32, String) -> Void
    ) throws {
        var arguments = [
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if let resume { arguments += ["--resume", resume] }
        try launch(prompt: prompt, systemPrompt: systemPrompt, allowedTools: allowedTools, extraArguments: arguments) { data in
            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            onEvent(event)
        } onFinish: { status, stderr in
            onFinish(status, stderr)
        }
    }

    /// One answer matching `jsonSchema`, returned as the decoded object.
    func runOnce(
        prompt: String,
        systemPrompt: String,
        allowedTools: String,
        jsonSchema: [String: Any]
    ) async throws -> [String: Any] {
        let schema = try JSONSerialization.data(withJSONObject: jsonSchema)
        let arguments = [
            "--output-format", "json",
            "--json-schema", String(decoding: schema, as: UTF8.self),
        ]
        return try await withCheckedThrowingContinuation { continuation in
            var output = Data()
            var resumed = false
            do {
                try launch(prompt: prompt, systemPrompt: systemPrompt, allowedTools: allowedTools, extraArguments: arguments,
                           splitLines: false) { data in
                    output.append(data)
                } onFinish: { status, stderr in
                    guard !resumed else { return }
                    resumed = true
                    guard let result = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: PGError(detail.isEmpty
                            ? "Claude Code exited with status \(status)" : String(detail.suffix(500))))
                        return
                    }
                    if result["is_error"] as? Bool == true {
                        continuation.resume(throwing: PGError(result["result"] as? String ?? "Claude Code reported an error"))
                        return
                    }
                    // `--json-schema` puts the structured answer in `result` as a JSON string.
                    guard let text = result["result"] as? String,
                          let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                    else {
                        continuation.resume(throwing: PGError("Claude Code returned an unexpected answer"))
                        return
                    }
                    continuation.resume(returning: answer)
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

    // MARK: Process plumbing

    private func launch(
        prompt: String,
        systemPrompt: String,
        allowedTools: String,
        extraArguments: [String],
        splitLines: Bool = true,
        onData: @escaping (Data) -> Void,
        onFinish: @escaping (Int32, String) -> Void
    ) throws {
        guard let executable = ClaudeCLI.executableURL else {
            throw PGError("Claude Code isn't installed. Install it from claude.com/claude-code and run `claude` once to sign in.")
        }
        let directory = ClaudeCLI.workingDirectory
        let mcpConfigURL = directory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        try writeMCPConfig(to: mcpConfigURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-p",
            "--tools", "",  // no shell or file tools, only Arsip's database tools
            "--mcp-config", mcpConfigURL.path,
            "--strict-mcp-config",
            "--allowedTools", allowedTools,
            "--permission-mode", "dontAsk",
            "--setting-sources", "",
            "--append-system-prompt", systemPrompt,
        ] + extraArguments
        process.currentDirectoryURL = directory
        process.environment = ClaudeCLI.environment

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
                        try? FileManager.default.removeItem(at: mcpConfigURL)
                        if self?.process == process { self?.process = nil }
                        onFinish(status, stderrBuffer.text)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: mcpConfigURL)
            throw PGError("Couldn't start Claude Code: \(error.localizedDescription)")
        }
        // The prompt goes over stdin so text starting with "-" can't be mistaken for a flag.
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        self.process = process
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
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
