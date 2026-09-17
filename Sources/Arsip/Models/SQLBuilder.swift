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
