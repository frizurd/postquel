import Foundation

/// A small MCP server over stdio (newline-delimited JSON-RPC 2.0) that gives an AI agent
/// read-only tools for one database. The agent CLI starts it as `Arsip --mcp-server` with the
/// connection details in the environment; it opens its own connection.
final class MCPServer {
    static let launchArgument = "--mcp-server"

    enum EnvironmentKey {
        static let host = "ARSIP_MCP_HOST"
        static let port = "ARSIP_MCP_PORT"
        static let user = "ARSIP_MCP_USER"
        static let database = "ARSIP_MCP_DATABASE"
        static let password = "ARSIP_MCP_PASSWORD"
    }

    private let connection: PGConnection?
    private let connectError: String?
    private let databaseLabel: String

    private init(connection: PGConnection?, connectError: String?, databaseLabel: String) {
        self.connection = connection
        self.connectError = connectError
        self.databaseLabel = databaseLabel
    }

    static func runFromEnvironment() -> Never {
        let environment = ProcessInfo.processInfo.environment
        var config = ConnectionConfig()
        config.host = environment[EnvironmentKey.host] ?? config.host
        config.port = environment[EnvironmentKey.port].flatMap(Int.init) ?? config.port
        config.user = environment[EnvironmentKey.user] ?? config.user
        config.database = environment[EnvironmentKey.database] ?? config.database
        config.password = environment[EnvironmentKey.password] ?? ""

        // Keep serving even if the connection fails, so the agent can report the error.
        var connection: PGConnection?
        var connectError: String?
        do {
            let opened = try PGConnection.open(config, applicationName: "Arsip AI (read-only)")
            opened.silenceNotices()  // stderr noise like "there is no transaction in progress"
            _ = opened.executeBlocking("SET default_transaction_read_only = on")
            _ = opened.executeBlocking("SET statement_timeout = '30s'")
            _ = opened.executeBlocking("SET idle_in_transaction_session_timeout = '60s'")
            connection = opened
        } catch {
            connectError = error.localizedDescription
        }

        let server = MCPServer(connection: connection, connectError: connectError,
                               databaseLabel: "\(config.database) on \(config.host)")
        while let line = readLine(strippingNewline: true) {
            server.handle(line)
        }
        exit(0)
    }

    // MARK: JSON-RPC

    private func handle(_ line: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let method = message["method"] as? String,
              let id = message["id"]  // notifications have no id and need no reply
        else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            respond(id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "arsip", "version": "0.1.0"],
                "instructions": "Read-only tools for the PostgreSQL database \(databaseLabel), plus tools that open tables and queries in the Arsip window.",
            ])
        case "ping":
            respond(id, result: [String: Any]())
        case "tools/list":
            respond(id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = callTool(name, arguments)
            respond(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func respond(_ id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: Tools

    private static let tools: [[String: Any]] = [
        [
            "name": "list_tables",
            "description": "List tables, views and materialized views with estimated row counts and comments.",
            "inputSchema": [
                "type": "object",
                "properties": ["schema": ["type": "string", "description": "Only list this schema"]],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "describe_table",
            "description": "Columns (type, nullability, default, comment), constraints (primary key, foreign keys, unique, check), "
                + "indexes, incoming foreign keys, size and estimated row count of one table or view.",
            "inputSchema": [
                "type": "object",
                "properties": ["table": ["type": "string", "description": "Table name, optionally schema-qualified, e.g. public.orders"]],
                "required": ["table"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "run_query",
            "description": "Run exactly ONE SQL statement in a READ ONLY transaction that is always rolled back. "
                + "Data modifications fail. Returns tab-separated rows with a header.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sql": ["type": "string", "description": "A single SQL statement"],
                    "max_rows": ["type": "integer", "description": "Rows to return (default 100, max 1000)"],
                ],
                "required": ["sql"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "explain_query",
            "description": "Show the query plan for ONE statement. With analyze=true the statement is executed "
                + "(still read-only, rolled back) to report actual timings and buffers.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sql": ["type": "string", "description": "A single SQL statement"],
                    "analyze": ["type": "boolean", "description": "Execute to get real timings (default false)"],
                ],
                "required": ["sql"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "open_table",
            "description": "Open a table or view in a new tab in the user's Arsip window, optionally filtered to rows "
                + "where columns equal given values (e.g. one customer's orders). Use this to show data instead of "
                + "pasting long results.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "table": ["type": "string", "description": "Table name, optionally schema-qualified"],
                    "filters": [
                        "type": "array",
                        "description": "Equality filters, combined with AND",
                        "items": [
                            "type": "object",
                            "properties": [
                                "column": ["type": "string"],
                                "value": ["type": "string", "description": "Value as text, e.g. \"42\" or \"refunded\""],
                            ],
                            "required": ["column", "value"],
                        ],
                    ],
                ],
                "required": ["table"],
            ],
        ],
        [
            "name": "open_query_tab",
            "description": "Open SQL in a new query tab in the user's Arsip window for them to review and run. "
                + "It is not executed. Use for longer read queries; use propose_change for changes.",
            "inputSchema": [
                "type": "object",
                "properties": ["sql": ["type": "string", "description": "The SQL to put in the tab"]],
                "required": ["sql"],
            ],
        ],
        [
            "name": "propose_change",
            "description": "Propose ONE data or schema change (INSERT, UPDATE, DELETE, MERGE, CREATE, ALTER, DROP, ...) "
                + "for the user to review. It is NOT applied: Arsip shows it as a card where the user can dry-run it "
                + "(run in a transaction and roll back) or apply it. Data changes are checked against the schema and "
                + "the planner's row estimate is returned. For several changes, call once per statement.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sql": ["type": "string", "description": "Exactly one statement, no BEGIN/COMMIT"],
                    "summary": ["type": "string", "description": "One short sentence describing the change for the user"],
                ],
                "required": ["sql", "summary"],
            ],
        ],
    ]

    private func callTool(_ name: String, _ arguments: [String: Any]) -> (String, Bool) {
        guard let connection else { return ("Not connected: \(connectError ?? "unknown error")", true) }
        switch name {
        case "list_tables":
            return listTables(connection, schema: arguments["schema"] as? String)
        case "describe_table":
            guard let table = arguments["table"] as? String else { return ("Missing argument: table", true) }
            return describeTable(connection, table)
        case "run_query":
            guard let sql = arguments["sql"] as? String else { return ("Missing argument: sql", true) }
            let maxRows = min(max((arguments["max_rows"] as? Int) ?? 100, 1), 1000)
            return readOnly(connection, sql) { format($0, maxRows: maxRows) }
        case "explain_query":
            guard let sql = arguments["sql"] as? String else { return ("Missing argument: sql", true) }
            let options = (arguments["analyze"] as? Bool) == true ? "ANALYZE, BUFFERS, FORMAT TEXT" : "FORMAT TEXT"
            return readOnly(connection, "EXPLAIN (\(options)) \(sql)") { plan in
                (0..<plan.rowCount).compactMap { plan.value(row: $0, column: 0) }.joined(separator: "\n")
            }
        case "open_table":
            guard let table = arguments["table"] as? String else { return ("Missing argument: table", true) }
            return validateOpenTable(connection, table, filters: arguments["filters"] as? [[String: Any]] ?? [])
        case "propose_change":
            guard let sql = arguments["sql"] as? String, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("Missing argument: sql", true)
            }
            return proposeChange(connection, sql)
        case "open_query_tab":
            guard let sql = arguments["sql"] as? String, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("Missing argument: sql", true)
            }
            return ("Opened a new query tab in Arsip with the SQL. It has not been run; the user decides whether to run it.", false)
        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    /// Runs one statement inside BEGIN READ ONLY … ROLLBACK. The single-statement protocol means the
    /// SQL can't end the transaction and continue with a write.
    private func readOnly(_ connection: PGConnection, _ sql: String, render: (PGResult) -> String) -> (String, Bool) {
        if let error = connection.executeBlocking("BEGIN READ ONLY").error { return (error, true) }
        defer { _ = connection.executeBlocking("ROLLBACK") }

        let outcome = connection.executeBlocking(sql, singleStatement: true)
        if let error = outcome.error { return (error, true) }
        guard let statement = outcome.results.last else { return ("OK", false) }
        guard let rows = statement.rows else { return (statement.status, false) }
        return (render(rows), false)
    }

    /// Validates a proposed change without applying it. Data changes are EXPLAINed inside a read-only
    /// transaction (planning doesn't execute, so this works for writes); DDL can't be checked this way.
    private func proposeChange(_ connection: PGConnection, _ sql: String) -> (String, Bool) {
        let keyword = Self.firstKeyword(sql)
        if ["BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE"].contains(keyword) {
            return ("Propose only the change itself. Arsip runs it in its own transaction.", true)
        }
        if ["SELECT", "SHOW", "EXPLAIN", "VALUES", "TABLE"].contains(keyword) {
            return ("That's a read query. Use run_query to run it, or open_query_tab to show it.", true)
        }

        var estimate = "n/a (schema changes can't be estimated)"
        if ["INSERT", "UPDATE", "DELETE", "MERGE", "WITH"].contains(keyword) {
            let (plan, isError) = readOnly(connection, "EXPLAIN \(sql)") { plan in
                (0..<plan.rowCount).compactMap { plan.value(row: $0, column: 0) }.joined(separator: "\n")
            }
            if isError { return (plan, true) }
            estimate = "~\(Self.estimatedRows(fromPlan: plan)) rows"
        }
        return ("""
            Proposed to the user for review. It has NOT been applied.
            Statement: \(keyword)
            Planner estimate: \(estimate)
            The user can dry-run it or apply it in Arsip. Don't repeat the SQL in your reply.
            """, false)
    }

    /// First word of the statement, skipping whitespace and `--` comments.
    static func firstKeyword(_ sql: String) -> String {
        let lines = sql.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }
        return String((lines.first ?? "").prefix { $0.isLetter }).uppercased()
    }

    /// Row estimate of the node under ModifyTable (which itself always reports rows=0).
    static func estimatedRows(fromPlan plan: String) -> Int {
        let rows = plan.components(separatedBy: "\n").compactMap { line -> Int? in
            guard let range = line.range(of: #"rows=(\d+)"#, options: .regularExpression) else { return nil }
            return Int(line[range].dropFirst(5))
        }
        return rows.dropFirst().first ?? rows.first ?? 0
    }

    /// Arsip opens the tab when it sees this succeed, so check everything it will need first.
    private func validateOpenTable(_ connection: PGConnection, _ table: String, filters: [[String: Any]]) -> (String, Bool) {
        let lookup = connection.executeBlocking("""
            SELECT n.nspname, c.relname
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.oid = to_regclass($1)
            """, params: [table])
        if let error = lookup.error { return (error, true) }
        guard let rows = lookup.results.first?.rows, rows.rowCount == 1,
              let schema = rows.value(row: 0, column: 0), let name = rows.value(row: 0, column: 1)
        else { return ("Table not found: \(table). Use list_tables to see what exists.", true) }

        let columnLookup = connection.executeBlocking("""
            SELECT attname FROM pg_attribute
            WHERE attrelid = to_regclass($1) AND attnum > 0 AND NOT attisdropped
            """, params: [table])
        let columnRows = columnLookup.results.first?.rows
        let columns = Set((0..<(columnRows?.rowCount ?? 0)).compactMap { columnRows?.value(row: $0, column: 0) })

        var descriptions: [String] = []
        for filter in filters {
            guard let column = filter["column"] as? String, filter["value"] != nil else {
                return ("Each filter needs a column and a value", true)
            }
            guard columns.contains(column) else { return ("Column \(column) doesn't exist in \(schema).\(name)", true) }
            descriptions.append("\(column) = \(filter["value"]!)")
        }
        let filterText = descriptions.isEmpty ? "" : " filtered by " + descriptions.joined(separator: " AND ")
        return ("Opened \(schema).\(name)\(filterText) in a new tab in Arsip.", false)
    }

    private func listTables(_ connection: PGConnection, schema: String?) -> (String, Bool) {
        let sql = """
            SELECT n.nspname || '.' || c.relname AS name,
                   CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
                                  WHEN 'm' THEN 'materialized view' WHEN 'f' THEN 'foreign table' END AS kind,
                   GREATEST(c.reltuples, 0)::bigint AS estimated_rows,
                   obj_description(c.oid, 'pg_class') AS comment
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND NOT c.relispartition
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_toast%'
              AND n.nspname NOT LIKE 'pg_temp%'
              AND ($1::text IS NULL OR n.nspname = $1)
            ORDER BY 1
            """
        let outcome = connection.executeBlocking(sql, params: [schema])
        if let error = outcome.error { return (error, true) }
        guard let rows = outcome.results.first?.rows else { return ("No result", true) }
        return (format(rows, maxRows: 2000), false)
    }

    private func describeTable(_ connection: PGConnection, _ table: String) -> (String, Bool) {
        let lookup = connection.executeBlocking("SELECT to_regclass($1)::oid", params: [table])
        if let error = lookup.error { return (error, true) }
        guard let oid = lookup.results.first?.rows?.value(row: 0, column: 0) else {
            return ("Table not found: \(table). Use list_tables to see what exists.", true)
        }

        let sections: [(String, String)] = [
            ("Overview", """
                SELECT c.oid::regclass::text AS name,
                       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
                                      WHEN 'm' THEN 'materialized view' WHEN 'f' THEN 'foreign table' ELSE c.relkind::text END AS kind,
                       GREATEST(c.reltuples, 0)::bigint AS estimated_rows,
                       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
                       obj_description(c.oid, 'pg_class') AS comment
                FROM pg_class c WHERE c.oid = $1::oid
                """),
            ("Columns", """
                SELECT a.attname AS column, format_type(a.atttypid, a.atttypmod) AS type,
                       CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE 'nullable' END AS nullability,
                       pg_get_expr(d.adbin, d.adrelid) AS default,
                       col_description(a.attrelid, a.attnum) AS comment
                FROM pg_attribute a
                LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped
                ORDER BY a.attnum
                """),
            ("Constraints", """
                SELECT conname AS name, pg_get_constraintdef(oid) AS definition
                FROM pg_constraint WHERE conrelid = $1::oid
                ORDER BY contype, conname
                """),
            ("Indexes", """
                SELECT pg_get_indexdef(indexrelid) AS definition
                FROM pg_index WHERE indrelid = $1::oid
                """),
            ("Referenced by", """
                SELECT conrelid::regclass::text AS table, pg_get_constraintdef(oid) AS definition
                FROM pg_constraint WHERE confrelid = $1::oid AND contype = 'f'
                """),
            ("View definition", """
                SELECT pg_get_viewdef($1::oid, true) AS definition
                FROM pg_class WHERE oid = $1::oid AND relkind IN ('v', 'm')
                """),
        ]

        var output: [String] = []
        for (title, sql) in sections {
            let outcome = connection.executeBlocking(sql, params: [oid])
            if let error = outcome.error { return ("\(title): \(error)", true) }
            guard let rows = outcome.results.first?.rows, rows.rowCount > 0 else { continue }
            output.append("## \(title)\n" + format(rows, maxRows: 1000))
        }
        return (output.joined(separator: "\n\n"), false)
    }

    /// Tab-separated with a header; NULL spelled out; long values and control characters escaped.
    private func format(_ result: PGResult, maxRows: Int) -> String {
        func cell(_ value: String?) -> String {
            guard var value else { return "NULL" }
            if value.count > 500 { value = String(value.prefix(500)) + "…(truncated)" }
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        let columnCount = result.columns.count
        var lines = [result.columns.map(\.name).joined(separator: "\t")]
        for row in 0..<min(result.rowCount, maxRows) {
            lines.append((0..<columnCount).map { cell(result.value(row: row, column: $0)) }.joined(separator: "\t"))
        }
        if result.rowCount > maxRows {
            lines.append("(showing \(maxRows) of \(result.rowCount) rows)")
        } else {
            lines.append("(\(result.rowCount) \(result.rowCount == 1 ? "row" : "rows"))")
        }
        return lines.joined(separator: "\n")
    }
}
