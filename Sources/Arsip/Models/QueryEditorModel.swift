import Foundation
import Observation

@MainActor @Observable
final class QueryEditorModel {
    private static let textKey = "editor.text"

    @ObservationIgnored var connection: PGConnection?
    /// Current editor selection; updated on every caret move, so not observed.
    @ObservationIgnored private var selectedRange = NSRange(location: 0, length: 0)
    /// The statement ⌘↩ runs and the AI bar edits.
    private(set) var active: SQLStatements.Active?
    /// One AI prompt draft per statement, so switching statements switches drafts.
    private var prompts: [Int: String] = [:]
    @ObservationIgnored var onTextChange: (() -> Void)?

    var text: String
    private(set) var isRunning = false
    private(set) var results: [StatementResult] = []
    private(set) var error: String?
    private(set) var duration: TimeInterval?
    /// Note about what ⌘↩ actually ran, e.g. when several statements were selected.
    private(set) var lastRunNote: String?
    var selectedResultIndex = 0 {
        didSet { selectedCell = nil }
    }
    var selectedCell: CellSelection?

    init(restoreSavedText: Bool = false) {
        text = restoreSavedText
            ? UserDefaults.standard.string(forKey: Self.textKey)
                ?? "-- ⌘↩ runs the statement the cursor is in\nSELECT now(), version();\n"
            : ""
    }

    var rowResultIndices: [Int] {
        results.indices.filter { results[$0].rows != nil }
    }

    var currentResult: StatementResult? {
        results.indices.contains(selectedResultIndex) ? results[selectedResultIndex] : nil
    }

    var activeStatementText: String? {
        guard let active else { return nil }
        return (text as NSString).substring(with: active.range)
    }

    /// The AI prompt for the statement in focus.
    var promptDraft: String {
        get { prompts[active?.index ?? 0] ?? "" }
        set { prompts[active?.index ?? 0] = newValue }
    }

    func updateSelection(range: NSRange) {
        selectedRange = range
        refreshActiveStatement()
    }

    func refreshActiveStatement() {
        active = SQLStatements.active(in: text, for: selectedRange)
    }

    /// Runs exactly one statement: the selection, or the one the caret is in.
    func runCurrent() async {
        refreshActiveStatement()
        guard let statement = activeStatementText, let active else { return }
        lastRunNote = active.selectedCount > 1
            ? "Ran the first of \(active.selectedCount) selected statements"
            : nil
        await run(statement)
    }

    func run(_ sql: String) async {
        let sql = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let connection, !sql.isEmpty, !isRunning else { return }
        UserDefaults.standard.set(text, forKey: Self.textKey)

        isRunning = true
        defer { isRunning = false }
        let outcome = await connection.execute(sql)
        selectedCell = nil
        results = outcome.results
        error = outcome.error
        duration = outcome.duration
        selectedResultIndex = rowResultIndices.last ?? max(0, results.count - 1)
    }

    /// Replaces the statement in focus with generated SQL (or inserts it in an empty editor).
    func applyGenerated(_ sql: String) {
        let current = text as NSString
        if let range = active?.range, range.upperBound <= current.length {
            text = current.replacingCharacters(in: range, with: sql)
            selectedRange = NSRange(location: range.location, length: (sql as NSString).length)
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = sql
            selectedRange = NSRange(location: 0, length: 0)
        } else {
            text = text + (text.hasSuffix("\n") ? "\n" : "\n\n") + sql
        }
        refreshActiveStatement()
        onTextChange?()
    }

    func cancel() {
        connection?.cancel()
    }
}
