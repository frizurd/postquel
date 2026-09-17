import Foundation
import Observation

@MainActor @Observable
final class QueryEditorModel {
    private static let textKey = "editor.text"

    @ObservationIgnored var connection: PGConnection?
    /// Current editor selection; updated on every caret move, so not observed.
    @ObservationIgnored var selectedText: String?
    @ObservationIgnored var onTextChange: (() -> Void)?

    var text: String
    private(set) var isRunning = false
    private(set) var results: [StatementResult] = []
    private(set) var error: String?
    private(set) var duration: TimeInterval?
    var selectedResultIndex = 0

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
        results = outcome.results
        error = outcome.error
        duration = outcome.duration
        selectedResultIndex = rowResultIndices.last ?? max(0, results.count - 1)
    }

    func cancel() {
        connection?.cancel()
    }
}
