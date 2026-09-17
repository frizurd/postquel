import Foundation
import Observation

@MainActor @Observable
final class QueryEditorModel {
    private static let textKey = "editor.text"

    @ObservationIgnored var connection: PGConnection?
    /// Current editor selection; updated on every caret move, so not observed.
    @ObservationIgnored var selectedText: String?
    @ObservationIgnored var selectedRange = NSRange(location: 0, length: 0)
    @ObservationIgnored var onTextChange: (() -> Void)?

    var text: String
    private(set) var isRunning = false
    private(set) var results: [StatementResult] = []
    private(set) var error: String?
    private(set) var duration: TimeInterval?
    var selectedResultIndex = 0 {
        didSet { selectedCell = nil }
    }
    var selectedCell: CellSelection?

    init(restoreSavedText: Bool = false) {
        text = restoreSavedText
            ? UserDefaults.standard.string(forKey: Self.textKey)
                ?? "-- ⌘↩ runs the selection, or everything if nothing is selected\nSELECT now(), version();\n"
            : ""
    }

    var rowResultIndices: [Int] {
        results.indices.filter { results[$0].rows != nil }
    }

    var currentResult: StatementResult? {
        results.indices.contains(selectedResultIndex) ? results[selectedResultIndex] : nil
    }

    func runCurrent() async {
        let selection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await run(selection.isEmpty ? text : selection)
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

    /// Puts generated SQL in the editor: over the selection, or appended when there's other text.
    func applyGenerated(_ sql: String) {
        let current = text as NSString
        if selectedRange.length > 0, selectedRange.upperBound <= current.length {
            text = current.replacingCharacters(in: selectedRange, with: sql)
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = sql
        } else {
            text = text + (text.hasSuffix("\n") ? "\n" : "\n\n") + sql
        }
        onTextChange?()
    }

    func cancel() {
        connection?.cancel()
    }
}
