import Foundation

enum SQLBuilder {
    /// `DELETE FROM t WHERE (pk...) IN ((...), (...))`, with one parameter per key value.
    static func delete(from table: String, primaryKey: [String], keys: [[String]]) -> (String, [String?])? {
        guard !primaryKey.isEmpty, !keys.isEmpty else { return nil }
        var params: [String?] = []
        let tuples = keys.map { key -> String in
            let placeholders = key.map { value -> String in
                params.append(value)
                return "$\(params.count)"
            }
            return "(\(placeholders.joined(separator: ", ")))"
        }
        let columns = primaryKey.map(quoteIdent).joined(separator: ", ")
        let target = primaryKey.count == 1 ? columns : "(\(columns))"
        return ("DELETE FROM \(table) WHERE \(target) IN (\(tuples.joined(separator: ", ")))", params)
    }

    /// `INSERT INTO t (cols) VALUES (...)`, leaving out columns the user didn't fill in so
    /// their defaults apply. Returns nil when nothing was filled in.
    static func insert(into table: String, values: [String: String?], returning: [String] = []) -> (String, [String?])? {
        let suffix = returning.isEmpty ? "" : " RETURNING \(returning.map(quoteIdent).joined(separator: ", "))"
        let filled = values.filter { $0.value != nil }.sorted { $0.key < $1.key }
        guard !filled.isEmpty else { return ("INSERT INTO \(table) DEFAULT VALUES\(suffix)", []) }
        let columns = filled.map { quoteIdent($0.key) }.joined(separator: ", ")
        let placeholders = (1...filled.count).map { "$\($0)" }.joined(separator: ", ")
        return ("INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))\(suffix)", filled.map(\.value))
    }

    /// `SELECT * FROM t WHERE (pk...) IN ((...))`, to fetch rows back by key.
    static func select(from table: String, primaryKey: [String], keys: [[String]]) -> (String, [String?])? {
        guard let (delete, params) = delete(from: table, primaryKey: primaryKey, keys: keys) else { return nil }
        return (delete.replacingOccurrences(of: "DELETE FROM", with: "SELECT * FROM"), params)
    }

    /// Same statement with values inlined, for showing the user.
    static func inlined(_ sql: String, params: [String?]) -> String {
        var preview = sql
        for (index, value) in params.enumerated().reversed() {
            let literal = value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
            preview = preview.replacingOccurrences(of: "$\(index + 1)", with: literal)
        }
        return preview
    }
}
