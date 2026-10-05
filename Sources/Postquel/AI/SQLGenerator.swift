import Foundation
import Observation

/// Turns a plain-language request into SQL for the query editor. The selected agent inspects the real schema
/// through Postquel's read-only tools, so column names are checked rather than guessed.
@MainActor @Observable
final class SQLGenerator {
    private(set) var isRunning = false
    private(set) var error: String?
    /// One-line remark from the agent about assumptions it made.
    private(set) var note: String?

    @ObservationIgnored private let runner: AgentRunner
    @ObservationIgnored private let databaseName: String

    init(config: ConnectionConfig) {
        runner = AgentRunner(config: config)
        databaseName = config.database
    }

    func cancel() {
        runner.stop()
        isRunning = false
    }

    /// Returns SQL for `request`, or nil if it failed (see `error`).
    func generate(request: String, currentSQL: String, mentionedTables: [String]) async -> String? {
        guard !isRunning else { return nil }
        isRunning = true
        error = nil
        note = nil
        defer { isRunning = false }

        var prompt = "Write a PostgreSQL query for this request:\n\(request)\n"
        if !mentionedTables.isEmpty {
            prompt += "\nTables the user referenced: \(mentionedTables.joined(separator: ", ")). Check them with describe_table.\n"
        }
        let existing = currentSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            prompt += "\nThe editor currently contains this SQL. If the request is a change to it, rewrite it:\n"
                + "```sql\n\(String(existing.prefix(4000)))\n```\n"
        }

        do {
            let model = AgentCatalog.shared.selection
            let answer = try await runner.runOnce(
                model: model,
                prompt: prompt,
                systemPrompt: systemPrompt,
                // Schema and read-only queries only: no opening tabs or proposing changes from here.
                tools: ["list_tables", "describe_table", "run_query", "explain_query"],
                jsonSchema: [
                    "type": "object",
                    "properties": [
                        "sql": ["type": "string", "description": "The SQL, ready to run, without markdown fences"],
                        "note": ["type": "string", "description": "At most one short sentence about assumptions, or empty"],
                    ],
                    // Codex (OpenAI structured outputs) needs every property listed as required.
                    "required": ["sql", "note"],
                    "additionalProperties": false,
                ]
            )
            guard let sql = (answer["sql"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty else {
                error = "\(model.agent.shortName) didn't return any SQL"
                return nil
            }
            note = (answer["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return sql
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private var systemPrompt: String {
        """
        You write PostgreSQL for the SQL editor of Postquel, a database client. The database is \(databaseName).

        - Inspect the real schema with list_tables and describe_table before writing anything. Never guess \
        table or column names. You may run read-only queries to check values.
        - Answer with JSON: "sql" is the statement(s) to put in the editor, ready to run, with no markdown \
        fences or commentary; "note" is at most one short sentence about an assumption, or empty.
        - Write readable SQL: uppercase keywords, one clause per line, explicit column lists rather than *, \
        and a LIMIT on exploratory queries.
        - Only write a data or schema change if the user asked for one. It is put in the editor, not run.
        """
    }
}
