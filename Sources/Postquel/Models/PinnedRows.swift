import Foundation

/// A page of rows plus rows kept visible below it — a row just inserted usually belongs on the
/// last page, and would otherwise vanish on save. A refresh drops the pinned rows.
final class PinnedRows: GridSource {
    let page: PGResult
    let pinned: PGResult

    init(page: PGResult, pinned: PGResult) {
        self.page = page
        self.pinned = pinned
    }

    var columns: [PGColumn] { page.columns }
    var rowCount: Int { page.rowCount + pinned.rowCount }

    /// Rows from `page.rowCount` on are pinned ones.
    func isPinned(row: Int) -> Bool { row >= page.rowCount }

    func value(row: Int, column: Int) -> String? {
        isPinned(row: row)
            ? pinned.value(row: row - page.rowCount, column: column)
            : page.value(row: row, column: column)
    }
}
