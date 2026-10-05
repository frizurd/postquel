import Foundation
import Observation

/// A coding-agent CLI that Arsip can drive with its read-only MCP server.
enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor Agent"
        }
    }

    /// Name used in short labels: "Claude", "Codex".
    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        }
    }

    var executableURL: URL? { AgentCLI.executableURL(for: self) }

    /// Models this agent offers, "Default" (the agent's own choice) first.
    nonisolated func availableModels() -> [AgentModel] {
        let fallback = [AgentModel(agent: self, model: nil, name: "Default")]
        switch self {
        case .claude:
            // Claude Code has no listing command; these aliases always point at the latest of each.
            return fallback + [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
                .map { AgentModel(agent: self, model: $0.0, name: $0.1) }
        case .codex:
            guard let executable = executableURL,
                  let data = AgentCLI.output(of: executable, arguments: ["debug", "models"]),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else { return fallback }
            return fallback + models
                .filter { $0["visibility"] as? String == "list" }
                .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
                .compactMap { model in
                    guard let slug = model["slug"] as? String else { return nil }
                    return AgentModel(agent: self, model: slug, name: model["display_name"] as? String ?? slug)
                }
        case .cursor:
            // `cursor-agent models` prints "id - Name" lines; Default is Cursor's own Auto.
            guard let executable = executableURL,
                  let data = AgentCLI.output(of: executable, arguments: ["models"])
            else { return fallback }
            let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
            return fallback + String(decoding: data, as: UTF8.self).components(separatedBy: "\n").compactMap { line in
                let range = NSRange(line.startIndex..., in: line)
                let plain = ansi?.stringByReplacingMatches(in: line, range: range, withTemplate: "") ?? line
                let parts = plain.components(separatedBy: " - ")
                guard parts.count >= 2 else { return nil }
                let slug = parts[0].trimmingCharacters(in: .whitespaces)
                guard !slug.isEmpty, !slug.contains(" "), slug != "auto" else { return nil }
                let name = parts.dropFirst().joined(separator: " - ")
                    .replacingOccurrences(of: "(default)", with: "")
                    .replacingOccurrences(of: "(current)", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return AgentModel(agent: self, model: slug, name: name.isEmpty ? slug : name)
            }
        }
    }
}

/// One agent + model choice. `model` nil means the agent's default.
struct AgentModel: Hashable, Identifiable, Sendable {
    let agent: AgentKind
    let model: String?
    let name: String

    var id: String { storageKey }

    var storageKey: String { agent.rawValue + (model.map { ":" + $0 } ?? "") }

    /// "Claude", "Claude · Opus", "Codex · GPT-6.1-Sol".
    var title: String { model == nil ? agent.shortName : "\(agent.shortName) · \(name)" }

    init(agent: AgentKind, model: String?, name: String) {
        self.agent = agent
        self.model = model
        self.name = name
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard let agent = parts.first.flatMap(AgentKind.init(rawValue:)) else { return nil }
        self.init(agent: agent, model: parts.count > 1 ? parts[1] : nil, name: parts.count > 1 ? parts[1] : "Default")
    }
}

/// The agents installed on this Mac, their models, and which one the assistant uses.
@MainActor @Observable
final class AgentCatalog {
    static let shared = AgentCatalog()
    private static let selectionKey = "assistantModel"

    private(set) var installed: [AgentKind] = []
    private(set) var models: [AgentKind: [AgentModel]] = [:]
    private(set) var isLoaded = false

    var selection: AgentModel {
        didSet { UserDefaults.standard.set(selection.storageKey, forKey: Self.selectionKey) }
    }

    private init() {
        selection = UserDefaults.standard.string(forKey: Self.selectionKey).flatMap(AgentModel.init(storageKey:))
            ?? AgentModel(agent: .claude, model: nil, name: "Default")
        Task { await load() }
    }

    func models(for agent: AgentKind) -> [AgentModel] { models[agent] ?? [] }

    private func load() async {
        let found = await Task.detached {
            AgentKind.allCases.map { agent in (agent, agent.executableURL == nil ? nil : agent.availableModels()) }
        }.value
        installed = found.compactMap { $0.1 == nil ? nil : $0.0 }
        for case let (agent, list?) in found { models[agent] = list }

        // Keep the saved choice when it's still available, otherwise fall back to an installed default.
        if let match = models(for: selection.agent).first(where: { $0.model == selection.model }) {
            selection = match
        } else if let first = installed.first, let fallback = models(for: installed.contains(selection.agent) ? selection.agent : first).first {
            selection = fallback
        }
        isLoaded = true
    }
}

/// Finding and running agent CLIs from a GUI app, which doesn't get the user's shell PATH.
enum AgentCLI {
    private static let claudeURL = locate("claude", extra: ["\(home)/.claude/local/claude"])
    private static let codexURL = locate("codex")
    private static let cursorURL = locate("cursor-agent")

    static func executableURL(for agent: AgentKind) -> URL? {
        switch agent {
        case .claude: claudeURL
        case .codex: codexURL
        case .cursor: cursorURL
        }
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private static func locate(_ command: String, extra: [String] = []) -> URL? {
        let candidates = ["\(home)/.local/bin/\(command)", "/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"] + extra
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to the login shell's PATH.
        guard let data = output(of: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v \(command)"]) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Runs a short command and returns its stdout, or nil if it fails or takes longer than `timeout`.
    static func output(of executable: URL, arguments: [String], timeout: TimeInterval = 15) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = LockedBuffer()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus == 0 ? output.data : nil
    }

    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }()

    /// Removes Cursor workspaces left by earlier launches: a runner deletes its own when it goes away,
    /// but quitting the app doesn't give it the chance. Call once at launch, before any run.
    static func removeStaleWorkspaces() {
        let directory = workingDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in entries where entry.hasPrefix("cursor-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// An empty directory, so no project CLAUDE.md, AGENTS.md or settings get picked up.
    static var workingDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arsip/Assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
