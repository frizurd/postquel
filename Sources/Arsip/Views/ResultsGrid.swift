import AppKit
import SwiftUI

/// Spreadsheet-style result grid backed by a view-based NSTableView.
/// Cells are read lazily from the PGResult, so large results scroll smoothly.
struct ResultsGrid: NSViewRepresentable {
    var result: PGResult?
    var sort: GridSort? = nil
    var sortable = false
    var editable = false
    /// Data column indices that get a "follow foreign key" button.
    var linkColumns: Set<Int> = []
    var onFollowLink: ((_ row: Int, _ column: Int) -> Void)? = nil
    var onSort: ((GridSort?) -> Void)? = nil
    var onEdit: ((_ row: Int, _ column: Int, _ value: String?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = GridTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnSelection = false
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.copyHandler = { [weak coordinator] in coordinator?.copyRows(includeHeaders: false) }
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(result: result, sort: sort, linkColumns: linkColumns)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: ResultsGrid
        weak var table: GridTableView?
        private var result: PGResult?
        private var linkColumns: Set<Int> = []
        private var syncingSort = false
        private var editingCell: (row: Int, column: Int)?
        private var editCancelled = false

        init(parent: ResultsGrid) { self.parent = parent }

        func apply(result: PGResult?, sort: GridSort?, linkColumns: Set<Int>) {
            guard let table else { return }
            if result !== self.result || linkColumns != self.linkColumns {
                let sameShape = result?.columns == self.result?.columns && !table.tableColumns.isEmpty
                self.result = result
                self.linkColumns = linkColumns
                // Keep widths/order/scroll when a reload returns the same columns (paging, sorting, edits).
                if !sameShape { rebuildColumns(table) }
                table.reloadData()
            }
            syncSortIndicator(table, sort: sort)
        }

        private func rebuildColumns(_ table: NSTableView) {
            for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
            guard let result else { return }
            for (index, column) in result.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: .init(String(index)))
                tableColumn.title = column.name
                tableColumn.headerToolTip = "\(column.name) · \(column.typeName)"
                tableColumn.minWidth = 40
                tableColumn.maxWidth = 2000
                tableColumn.width = estimatedWidth(column: index) + (linkColumns.contains(index) ? 18 : 0)
                if column.isNumeric { tableColumn.headerCell.alignment = .right }
                if parent.sortable {
                    tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.name, ascending: true)
                }
                table.addTableColumn(tableColumn)
            }
            table.scroll(.zero)
        }

        private func estimatedWidth(column: Int) -> CGFloat {
            guard let result else { return 120 }
            var longest = result.columns[column].name.count + 2
            for row in 0..<min(result.rowCount, 100) {
                longest = max(longest, min(result.value(row: row, column: column)?.count ?? 4, 60))
            }
            return min(max(CGFloat(longest) * 7 + 22, 60), 420)
        }

        private func syncSortIndicator(_ table: NSTableView, sort: GridSort?) {
            guard parent.sortable else { return }
            let desired = sort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
            guard table.sortDescriptors != desired else { return }
            syncingSort = true
            table.sortDescriptors = desired
            syncingSort = false
        }

        private func dataColumn(_ tableColumn: NSTableColumn?) -> Int? {
            tableColumn.flatMap { Int($0.identifier.rawValue) }
        }

        // MARK: Data source & delegate

        func numberOfRows(in tableView: NSTableView) -> Int { result?.rowCount ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let result, let column = dataColumn(tableColumn) else { return nil }
            let cell = tableView.makeView(withIdentifier: GridCell.reuseIdentifier, owner: nil) as? GridCell ?? GridCell()
            let value = result.value(row: row, column: column)
            cell.show(value, alignRight: result.columns[column].isNumeric,
                      showsLink: value != nil && linkColumns.contains(column))
            cell.field.delegate = self
            cell.linkButton.target = self
            cell.linkButton.action = #selector(followLink(_:))
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncingSort else { return }
            let sort = tableView.sortDescriptors.first.flatMap { descriptor in
                descriptor.key.map { GridSort(column: $0, ascending: descriptor.ascending) }
            }
            parent.onSort?(sort)
        }

        @objc func followLink(_ sender: NSButton) {
            guard let table else { return }
            let row = table.row(for: sender), columnIndex = table.column(for: sender)
            guard row >= 0, columnIndex >= 0, let column = dataColumn(table.tableColumns[columnIndex]) else { return }
            parent.onFollowLink?(row, column)
        }

        // MARK: Editing

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow, columnIndex = sender.clickedColumn
            guard parent.editable, row >= 0, columnIndex >= 0, let result,
                  let column = dataColumn(sender.tableColumns[columnIndex]),
                  let cell = sender.view(atColumn: columnIndex, row: row, makeIfNecessary: false) as? GridCell
            else { return }

            let value = result.value(row: row, column: column)
            // Single-line field editor would mangle multi-line values; a proper value editor comes later.
            if value?.contains("\n") == true {
                NSSound.beep()
                return
            }
            editingCell = (row, column)
            editCancelled = false
            cell.beginEditing(value)
            sender.window?.makeFirstResponder(cell.field)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                editCancelled = true
                control.window?.makeFirstResponder(table)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let editing = editingCell, let table, let result else { return }
            editingCell = nil
            field.isEditable = false

            let original = result.value(row: editing.row, column: editing.column)
            let newValue = field.stringValue
            let unchanged = newValue == original || (original == nil && newValue.isEmpty)
            if editCancelled || unchanged {
                table.reloadData(forRowIndexes: [editing.row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                return
            }
            parent.onEdit?(editing.row, editing.column, newValue)
        }

        // MARK: Context menu & copy

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0 else { return }
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
            }
            if table.clickedColumn >= 0 {
                menu.addItem(item("Copy Value", #selector(copyClickedValue)))
            }
            menu.addItem(item("Copy Rows", #selector(copyRowsMenu)))
            menu.addItem(item("Copy Rows with Headers", #selector(copyRowsWithHeadersMenu)))
            if parent.editable, table.clickedColumn >= 0 {
                menu.addItem(.separator())
                menu.addItem(item("Set to NULL", #selector(setClickedNull)))
            }
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func copyClickedValue() {
            guard let table, let result, let column = dataColumn(table.tableColumns[table.clickedColumn]) else { return }
            writeToPasteboard(result.value(row: table.clickedRow, column: column) ?? "NULL")
        }

        @objc private func copyRowsMenu() { copyRows(includeHeaders: false) }
        @objc private func copyRowsWithHeadersMenu() { copyRows(includeHeaders: true) }

        @objc private func setClickedNull() {
            guard let table, let result, let column = dataColumn(table.tableColumns[table.clickedColumn]),
                  result.value(row: table.clickedRow, column: column) != nil
            else { return }
            parent.onEdit?(table.clickedRow, column, nil)
        }

        /// Tab-separated, in the columns' current on-screen order.
        func copyRows(includeHeaders: Bool) {
            guard let table, let result, !table.selectedRowIndexes.isEmpty else { return }
            let columns = table.tableColumns.compactMap(dataColumn)
            var lines: [String] = []
            if includeHeaders { lines.append(columns.map { result.columns[$0].name }.joined(separator: "\t")) }
            for row in table.selectedRowIndexes {
                lines.append(columns.map { result.value(row: row, column: $0) ?? "" }.joined(separator: "\t"))
            }
            writeToPasteboard(lines.joined(separator: "\n"))
        }

        private func writeToPasteboard(_ string: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }
}

final class GridTableView: NSTableView {
    var copyHandler: (() -> Void)?

    @objc func copy(_ sender: Any?) { copyHandler?() }
}

final class GridCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("GridCell")
    // SF with fixed-width digits so numeric columns still line up.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
    private static let nullFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

    let field = NSTextField(labelWithString: "")
    let linkButton = NSButton()
    private var fieldToEdge: NSLayoutConstraint!
    private var fieldToButton: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        field.font = Self.font
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field

        linkButton.image = NSImage(systemSymbolName: "chevron.right.circle.fill", accessibilityDescription: "Open referenced row")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        linkButton.isBordered = false
        linkButton.imagePosition = .imageOnly
        linkButton.contentTintColor = .secondaryLabelColor
        linkButton.toolTip = "Open referenced row in a new tab"
        linkButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(linkButton)

        fieldToEdge = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        fieldToButton = field.trailingAnchor.constraint(equalTo: linkButton.leadingAnchor, constant: -3)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldToEdge,
            linkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            linkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            linkButton.widthAnchor.constraint(equalToConstant: 14),
            linkButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ value: String?, alignRight: Bool, showsLink: Bool) {
        field.isEditable = false
        linkButton.isHidden = !showsLink
        fieldToEdge.isActive = !showsLink
        fieldToButton.isActive = showsLink
        field.alignment = alignRight ? .right : .left
        if let value {
            // Keep cells single-line and cheap to lay out.
            let preview = value.count > 300 ? String(value.prefix(300)) + "…" : value
            field.stringValue = preview.replacingOccurrences(of: "\n", with: " ↵ ")
            field.font = Self.font
            field.textColor = .labelColor
        } else {
            field.stringValue = "NULL"
            field.font = Self.nullFont
            field.textColor = .tertiaryLabelColor
        }
    }

    func beginEditing(_ value: String?) {
        field.stringValue = value ?? ""
        field.font = Self.font
        field.textColor = .labelColor
        field.isEditable = true
    }
}
