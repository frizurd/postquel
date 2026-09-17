import Foundation
import Observation

struct GridSort: Equatable, Codable {
    var column: String
    var ascending: Bool
}

/// `column = value` restriction, e.g. from following a foreign key.
struct ColumnFilter: Hashable, Codable {
    let column: String
    let value: String
}

struct CellSelection: Hashable {
    let row: Int
    let column: Int
}

struct ForeignKey {
    let columns: [String]
    let target: RelationRef
    let targetColumns: [String]
}

@MainActor @Observable
final class TableBrowserModel {
    let relation: RelationRef
    let pageSize = 1000
    private let connection: PGConnection
    @ObservationIgnored private var started = false
    /// Called when filters or sort change, so the workspace can be saved.
    @ObservationIgnored var onStateChange: (() -> Void)?

    private(set) var result: PGResult?
    /// Rows kept visible after being inserted, until the next refresh.
    private(set) var pinnedResult: PGResult?
    @ObservationIgnored private var pinnedKeys: [[String]] = []
    /// What the grid shows: the page, plus any pinned rows below it.
    private(set) var gridSource: GridSource?
    private(set) var primaryKey: [String] = []
    private(set) var foreignKeys: [ForeignKey] = []
    private(set) var estimatedRows: Int?
    private(set) var isLoading = false
    private(set) var lastDuration: TimeInterval = 0
    private(set) var filters: [ColumnFilter]
    var error: String?
    var selectedCell: CellSelection?
    var selectedRows = IndexSet()
    /// Rows staged for deletion, held by primary key so they survive reloads.
    private(set) var pendingDeletions: Set<[String]> = []
    /// Values typed into the blank row at the bottom; nil when there's no new row.
    private(set) var draftRow: [String: String?]?
    /// Set when ⌘R is pressed with unsaved deletions.
    var confirmingRefresh = false
    private(set) var isSaving = false
    var sort: GridSort?
    var page = 0

    init(relation: RelationRef, connection: PGConnection, filters: [ColumnFilter] = [], sort: GridSort? = nil) {
        self.relation = relation
        self.connection = connection
        self.filters = filters
        self.sort = sort
    }

    var title: String {
        guard !filters.isEmpty else { return relation.name }
        return relation.name + " · " + filterDescription
    }

    var filterDescription: String {
        filters.map { "\($0.column) = \($0.value)" }.joined(separator: " AND ")
    }

    var canEdit: Bool { relation.kind == .table && !primaryKey.isEmpty }

    var hasPendingChanges: Bool { !pendingDeletions.isEmpty || draftRow != nil }

    var pendingSummary: String {
        var parts: [String] = []
        if !pendingDeletions.isEmpty {
            parts.append("\(pendingDeletions.count) \(pendingDeletions.count == 1 ? "row" : "rows") to delete")
        }
        if draftRow != nil { parts.append("1 new row") }
        return parts.joined(separator: " · ")
    }

    func beginNewRow() {
        guard canEdit, draftRow == nil else { return }
        draftRow = [:]
    }

    func setDraftValue(column: Int, value: String?) {
        guard let source = gridSource, column < source.columns.count, draftRow != nil else { return }
        draftRow?[source.columns[column].name] = value
    }

    /// Draft values by result column index, for the grid.
    var draftValues: [Int: String]? {
        guard let draftRow, let source = gridSource else { return nil }
        var values: [Int: String] = [:]
        for (index, column) in source.columns.enumerated() {
            if let value = draftRow[column.name] ?? nil { values[index] = value }
        }
        return values
    }

    func discardDraftRow() {
        draftRow = nil
    }

    /// Result rows currently staged for deletion.
    var markedRows: IndexSet {
        guard let result, !pendingDeletions.isEmpty else { return IndexSet() }
        var rows = IndexSet()
        for row in 0..<result.rowCount where pendingDeletions.contains(keyValues(of: row, in: result)) {
            rows.insert(row)
        }
        return rows
    }

    func markSelectedForDeletion() {
        guard canEdit, let result else { return }
        for row in selectedRows where row < result.rowCount {
            pendingDeletions.insert(keyValues(of: row, in: result))
        }
    }

    func discardPendingDeletions() {
        pendingDeletions = []
    }

    func discardPendingChanges() {
        pendingDeletions = []
        draftRow = nil
    }

    /// The statements Save Changes runs, with values inlined for display.
    var pendingChangesPreview: String? {
        let preview = pendingStatements().map { SQLBuilder.inlined($0.sql, params: $0.params) + ";" }
        return preview.isEmpty ? nil : preview.joined(separator: "\n\n")
    }

    /// Applies the new row and the deletions together, in one transaction.
    func savePendingChanges() async {
        let statements = pendingStatements()
        guard !statements.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let expected = pendingDeletions.count
        let outcome = await connection.executeInTransaction(statements, commit: true)
        if let message = outcome.error {
            error = message  // nothing was applied; the marks stay so the user can fix and retry
            return
        }
        // Keep the inserted row visible even though it belongs on the last page.
        if let inserted = outcome.results.first(where: { $0.status.hasPrefix("INSERT") })?.rows, inserted.rowCount > 0 {
            pinnedKeys.append((0..<inserted.columns.count).compactMap { inserted.value(row: 0, column: $0) })
        }
        let deleted = outcome.results.first(where: { $0.status.hasPrefix("DELETE") })?.affectedRows ?? 0
        error = expected == 0 || deleted == expected
            ? nil
            : "Deleted \(deleted) of \(expected) rows; the others were already gone"
        pendingDeletions = []
        draftRow = nil
        selectedRows = IndexSet()
        await load()
    }

    /// Insert first, so a new row can reuse a key that's being deleted in the same save.
    private func pendingStatements() -> [(sql: String, params: [String?])] {
        var statements: [(sql: String, params: [String?])] = []
        if let draftRow, let insert = SQLBuilder.insert(into: relation.qualifiedName, values: draftRow,
                                                       returning: primaryKey) {
            statements.append(insert)
        }
        if let delete = deleteStatement() { statements.append(delete) }
        return statements
    }

    private func deleteStatement() -> (String, [String?])? {
        guard canEdit, !pendingDeletions.isEmpty else { return nil }
        return SQLBuilder.delete(from: relation.qualifiedName, primaryKey: primaryKey, keys: Array(pendingDeletions))
    }

    private func keyValues(of row: Int, in result: PGResult) -> [String] {
        primaryKey.map { name in
            result.columns.firstIndex { $0.name == name }
                .flatMap { result.value(row: row, column: $0) } ?? ""
        }
    }

    var readOnlyReason: String? {
        if relation.kind != .table { return "Read-only (not a table)" }
        if primaryKey.isEmpty { return "Read-only (no primary key)" }
        return nil
    }

    /// Result column indices that are part of a foreign key.
    var linkColumns: Set<Int> {
        guard let result, !foreignKeys.isEmpty else { return [] }
        let names = Set(foreignKeys.flatMap(\.columns))
        return Set(result.columns.indices.filter { names.contains(result.columns[$0].name) })
    }

    /// Where following the foreign key in this cell leads, or nil if any key value is NULL.
    func linkTarget(row: Int, column: Int) -> (relation: RelationRef, filters: [ColumnFilter])? {
        guard let result else { return nil }
        let name = result.columns[column].name
        guard let key = foreignKeys.first(where: { $0.columns.contains(name) }) else { return nil }

        var filters: [ColumnFilter] = []
        for (source, target) in zip(key.columns, key.targetColumns) {
            guard let index = result.columns.firstIndex(where: { $0.name == source }),
                  let value = result.value(row: row, column: index)
            else { return nil }
            filters.append(ColumnFilter(column: target, value: value))
        }
        return (key.target, filters)
    }

    /// Loads once; switching tabs back and forth doesn't refetch.
    func start() async {
        guard !started else { return }
        started = true
        await loadMetadata()
        await load()
    }

    /// ⌘R: also drops pinned rows, so everything sits in its real position again.
    func reload() async {
        pinnedKeys = []
        pinnedResult = nil
        await loadMetadata()
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        var sql = "SELECT * FROM \(relation.qualifiedName)"
        var params: [String?] = []
        if !filters.isEmpty {
            sql += " WHERE " + filters.map { filter in
                params.append(filter.value)
                return "\(quoteIdent(filter.column)) = $\(params.count)"
            }.joined(separator: " AND ")
        }
        if let sort {
            sql += " ORDER BY \(quoteIdent(sort.column)) \(sort.ascending ? "ASC" : "DESC") NULLS LAST"
        } else if !primaryKey.isEmpty {
            // Stable order so paging and post-edit reloads don't shuffle rows.
            sql += " ORDER BY " + primaryKey.map(quoteIdent).joined(separator: ", ")
        }
        sql += " LIMIT \(pageSize) OFFSET \(page * pageSize)"

        let outcome = await connection.execute(sql, params: params)
        lastDuration = outcome.duration
        if let message = outcome.error {
            error = message
            return
        }
        error = nil
        result = outcome.results.last?.rows
        await loadPinnedRows()
    }

    /// Fetches pinned rows that aren't on this page, so a row just added stays in view.
    private func loadPinnedRows() async {
        guard let result else {
            gridSource = nil
            return
        }
        let onPage = Set((0..<result.rowCount).map { keyValues(of: $0, in: result) })
        let missing = pinnedKeys.filter { !onPage.contains($0) }
        guard !missing.isEmpty,
              let (sql, params) = SQLBuilder.select(from: relation.qualifiedName, primaryKey: primaryKey, keys: missing)
        else {
            pinnedResult = nil
            gridSource = result
            return
        }
        let outcome = await connection.execute(sql, params: params)
        if let rows = outcome.results.last?.rows, rows.rowCount > 0 {
            pinnedResult = rows
            gridSource = PinnedRows(page: result, pinned: rows)
        } else {
            pinnedResult = nil
            gridSource = result
        }
    }

    /// Rows displayed below the page because they were just added.
    var pinnedRowIndices: IndexSet {
        guard let composite = gridSource as? PinnedRows else { return IndexSet() }
        return IndexSet(integersIn: composite.page.rowCount..<composite.rowCount)
    }

    func clearFilters() async {
        pinnedKeys = []
        filters = []
        page = 0
        selectedCell = nil
        onStateChange?()
        await load()
    }

    func goToPage(_ newPage: Int) async {
        pinnedKeys = []
        page = max(0, newPage)
        selectedCell = nil
        await load()
    }

    func applySort(_ newSort: GridSort?) async {
        pinnedKeys = []
        sort = newSort
        page = 0
        selectedCell = nil
        onStateChange?()
        await load()
    }

    /// Writes one cell back, identifying the row by its primary key values.
    func update(row: Int, column: Int, value: String?) async {
        guard canEdit, let result else { return }

        var params: [String?] = [value]
        var predicates: [String] = []
        for key in primaryKey {
            guard let index = result.columns.firstIndex(where: { $0.name == key }) else {
                error = "Primary key column \(key) is not in the result"
                return
            }
            params.append(result.value(row: row, column: index))
            predicates.append("\(quoteIdent(key)) = $\(params.count)")
        }
        let sql = "UPDATE \(relation.qualifiedName) SET \(quoteIdent(result.columns[column].name)) = $1 WHERE "
            + predicates.joined(separator: " AND ")

        let outcome = await connection.execute(sql, params: params)
        if let message = outcome.error {
            error = message
            await load()
            return
        }
        if outcome.results.first?.affectedRows != 1 {
            error = "Expected to update 1 row, updated \(outcome.results.first?.affectedRows ?? 0)"
        }
        await load()
    }

    private func loadMetadata() async {
        let keySQL = """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = $1::regclass AND i.indisprimary
            ORDER BY array_position(i.indkey::int2[], a.attnum)
            """
        if let keys = await connection.execute(keySQL, params: [relation.qualifiedName]).results.first?.rows {
            primaryKey = (0..<keys.rowCount).compactMap { keys.value(row: $0, column: 0) }
        }

        let foreignKeySQL = """
            SELECT
                array_to_json(ARRAY(
                    SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                    JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
                    ORDER BY k.ord)),
                tn.nspname,
                tc.relname,
                array_to_json(ARRAY(
                    SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
                    JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum
                    ORDER BY k.ord))
            FROM pg_constraint con
            JOIN pg_class tc ON tc.oid = con.confrelid
            JOIN pg_namespace tn ON tn.oid = tc.relnamespace
            WHERE con.conrelid = $1::regclass AND con.contype = 'f'
            ORDER BY con.conname
            """
        if let keys = await connection.execute(foreignKeySQL, params: [relation.qualifiedName]).results.first?.rows {
            foreignKeys = (0..<keys.rowCount).compactMap { row in
                guard let columns = decodeNames(keys.value(row: row, column: 0)),
                      let schema = keys.value(row: row, column: 1),
                      let table = keys.value(row: row, column: 2),
                      let targetColumns = decodeNames(keys.value(row: row, column: 3))
                else { return nil }
                return ForeignKey(
                    columns: columns,
                    target: RelationRef(schema: schema, name: table, kind: .table),
                    targetColumns: targetColumns
                )
            }
        }

        let countSQL = "SELECT reltuples::bigint FROM pg_class WHERE oid = $1::regclass"
        if let counts = await connection.execute(countSQL, params: [relation.qualifiedName]).results.first?.rows,
           let estimate = counts.value(row: 0, column: 0).flatMap(Int.init), estimate >= 0 {
            estimatedRows = estimate
        }
    }

    private func decodeNames(_ json: String?) -> [String]? {
        json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }
}
