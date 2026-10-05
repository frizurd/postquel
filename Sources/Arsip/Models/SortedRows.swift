import Foundation

/// A result shown in another row order, for sorting query results by clicking a column header.
/// Sorts the rows already fetched; NULLs always go last, like `NULLS LAST` in table tabs.
final class SortedRows: GridSource {
    let base: GridSource
    private let order: [Int]

    init(base: GridSource, sort: GridSort) {
        self.base = base
        guard let column = base.columns.firstIndex(where: { $0.name == sort.column }) else {
            order = Array(0..<base.rowCount)
            return
        }
        let values = (0..<base.rowCount).map { base.value(row: $0, column: column) }
        let ascending = sort.ascending

        func before(_ lhs: Int, _ rhs: Int, _ result: ComparisonResult) -> Bool {
            switch result {
            case .orderedSame: lhs < rhs  // keep the query's order among equal values
            case .orderedAscending: ascending
            case .orderedDescending: !ascending
            }
        }

        if base.columns[column].isNumeric {
            let numbers = values.map { $0.flatMap(Double.init) }
            order = (0..<base.rowCount).sorted { lhs, rhs in
                switch (numbers[lhs], numbers[rhs]) {
                case (nil, nil): lhs < rhs
                case (nil, _): false
                case (_, nil): true
                case let (left?, right?):
                    before(lhs, rhs, left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending)
                }
            }
        } else {
            order = (0..<base.rowCount).sorted { lhs, rhs in
                switch (values[lhs], values[rhs]) {
                case (nil, nil): lhs < rhs
                case (nil, _): false
                case (_, nil): true
                case let (left?, right?):
                    before(lhs, rhs, left.compare(right, options: [.caseInsensitive, .numeric]))
                }
            }
        }
    }

    var columns: [PGColumn] { base.columns }
    var rowCount: Int { order.count }

    func value(row: Int, column: Int) -> String? {
        guard order.indices.contains(row) else { return nil }
        return base.value(row: order[row], column: column)
    }
}
