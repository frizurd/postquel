import AppKit
import SwiftUI

/// Spreadsheet-style result grid backed by a view-based NSTableView.
/// Cells are read lazily from the source, so large results scroll smoothly.
struct ResultsGrid: NSViewRepresentable {
    var source: GridSource?
    var sort: GridSort? = nil
    var sortable = false
    var editable = false
    /// Data column indices that get a "follow foreign key" button.
    var linkColumns: Set<Int> = []
    /// The cell shown in the value inspector (row index, data column index).
    var selectedCell: CellSelection? = nil
    var onSelectCell: ((CellSelection?) -> Void)? = nil
    /// Rows staged for deletion: drawn red instead of the selection color.
    var markedRows = IndexSet()
    /// Rows kept visible after being added, drawn with a tint.
    var pinnedRows = IndexSet()
    var onSelectRows: ((IndexSet) -> Void)? = nil
    /// ⌫ on the selected rows.
    var onDeleteRows: (() -> Void)? = nil
    /// Blank row at the bottom for a new record: values by data column, nil when there's none.
    var draftValues: [Int: String]? = nil
    var onEditDraft: ((_ column: Int, _ value: String?) -> Void)? = nil
    /// Double-click on a value the grid can't edit inline (multi-line, or a read-only grid).
    var onRequestInspector: (() -> Void)? = nil
    var onFollowLink: ((_ row: Int, _ column: Int) -> Void)? = nil
    var onSort: ((GridSort?) -> Void)? = nil
    var onEdit: ((_ row: Int, _ column: Int, _ value: String?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = GridTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = []  // alternating row colors separate the rows; no cell borders
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnSelection = false
        table.rowHeight = Theme.gridRowHeight
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.copyHandler = { [weak coordinator] in coordinator?.copyRows(includeHeaders: false) }
        table.deleteHandler = { [weak coordinator] in coordinator?.parent.onDeleteRows?() }
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
        context.coordinator.apply(source: source, sort: sort, linkColumns: linkColumns,
                                  selectedCell: selectedCell, markedRows: markedRows, pinnedRows: pinnedRows,
                                  draftValues: draftValues)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: ResultsGrid
        weak var table: GridTableView?
        private var result: GridSource?
        private var linkColumns: Set<Int> = []
        private var selectedCell: CellSelection?
        private var markedRows = IndexSet()
        private var pinnedRows = IndexSet()
        private var draftValues: [Int: String]?
        private var lastClickedColumn: Int?
        private var syncingSort = false
        private var editingCell: (row: Int, column: Int)?
        private var editCancelled = false

        init(parent: ResultsGrid) { self.parent = parent }

        func apply(source result: GridSource?, sort: GridSort?, linkColumns: Set<Int>, selectedCell: CellSelection?,
                   markedRows: IndexSet, pinnedRows: IndexSet, draftValues: [Int: String]?) {
            guard let table else { return }
            self.pinnedRows = pinnedRows
            let hadDraft = self.draftValues != nil
            self.draftValues = draftValues
            if hadDraft != (draftValues != nil) {
                table.reloadData()
                if draftValues != nil {
                    // Scroll again after layout: the changes bar appears at the same time and
                    // would otherwise cover the new row.
                    let lastRow = table.numberOfRows - 1
                    table.scrollRowToVisible(lastRow)
                    DispatchQueue.main.async { table.scrollRowToVisible(lastRow) }
                }
            }
            if markedRows != self.markedRows {
                self.markedRows = markedRows
                table.enumerateAvailableRowViews { rowView, row in
                    (rowView as? MarkedRowView)?.isMarked = markedRows.contains(row)
                }
            }
            if selectedCell != self.selectedCell {
                let previous = self.selectedCell
                self.selectedCell = selectedCell
                if selectedCell == nil, table.selectedRow >= 0 { table.deselectAll(nil) }
                let rows = IndexSet([previous?.row, selectedCell?.row].compactMap { $0 }.filter { $0 < table.numberOfRows })
                table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
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
                tableColumn.headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
                tableColumn.headerCell.textColor = .secondaryLabelColor
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

        private var draftRowIndex: Int? { draftValues != nil ? (result?.rowCount ?? 0) : nil }

        func numberOfRows(in tableView: NSTableView) -> Int {
            (result?.rowCount ?? 0) + (draftValues != nil ? 1 : 0)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let result, let column = dataColumn(tableColumn) else { return nil }
            let cell = tableView.makeView(withIdentifier: GridCell.reuseIdentifier, owner: nil) as? GridCell ?? GridCell()
            if row == draftRowIndex {
                cell.showDraft(draftValues?[column], alignRight: result.columns[column].isNumeric)
                cell.field.delegate = self
                return cell
            }
            let value = result.value(row: row, column: column)
            cell.show(value, alignRight: result.columns[column].isNumeric,
                      showsLink: value != nil && linkColumns.contains(column),
                      isInspected: selectedCell == CellSelection(row: row, column: column))
            cell.field.delegate = self
            cell.linkButton.target = self
            cell.linkButton.action = #selector(followLink(_:))
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: MarkedRowView.reuseIdentifier, owner: nil) as? MarkedRowView
                ?? MarkedRowView()
            rowView.isMarked = markedRows.contains(row)
            rowView.isDraft = row == draftRowIndex
            rowView.isPinned = pinnedRows.contains(row)
            return rowView
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

        // MARK: Selection

        @objc func clicked(_ sender: NSTableView) {
            let row = sender.clickedRow, columnIndex = sender.clickedColumn
            guard row >= 0, columnIndex >= 0, let column = dataColumn(sender.tableColumns[columnIndex]) else { return }
            lastClickedColumn = column
            parent.onSelectCell?(CellSelection(row: row, column: column))
        }

        /// Keyboard row changes keep the last clicked column.
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            parent.onSelectRows?(table.selectedRowIndexes)
            let row = table.selectedRow
            guard row >= 0, let result, !result.columns.isEmpty else {
                parent.onSelectCell?(nil)
                return
            }
            parent.onSelectCell?(CellSelection(row: row, column: min(lastClickedColumn ?? 0, result.columns.count - 1)))
        }

        // MARK: Editing

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow, columnIndex = sender.clickedColumn
            if row == draftRowIndex, columnIndex >= 0,
               let column = dataColumn(sender.tableColumns[columnIndex]),
               let cell = sender.view(atColumn: columnIndex, row: row, makeIfNecessary: false) as? GridCell {
                editingCell = (row, column)
                editCancelled = false
                cell.beginEditing(draftValues?[column])
                sender.window?.makeFirstResponder(cell.field)
                return
            }
            guard row >= 0, columnIndex >= 0, let result,
                  let column = dataColumn(sender.tableColumns[columnIndex]),
                  let cell = sender.view(atColumn: columnIndex, row: row, makeIfNecessary: false) as? GridCell
            else { return }

            let value = result.value(row: row, column: column)
            // The single-line field editor would mangle multi-line values; those go to the inspector.
            guard parent.editable, value?.contains("\n") != true else {
                parent.onRequestInspector?()
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

            if editing.row == draftRowIndex {
                if !editCancelled {
                    parent.onEditDraft?(editing.column, field.stringValue.isEmpty ? nil : field.stringValue)
                }
                table.reloadData(forRowIndexes: [editing.row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                return
            }

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
            if parent.editable {
                menu.addItem(.separator())
                if table.clickedColumn >= 0 {
                    menu.addItem(item("Set to NULL", #selector(setClickedNull)))
                }
                let count = table.selectedRowIndexes.count
                menu.addItem(item(count == 1 ? "Delete Row" : "Delete \(count) Rows", #selector(deleteSelectedRows)))
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

        @objc private func deleteSelectedRows() { parent.onDeleteRows?() }

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
    var deleteHandler: (() -> Void)?

    @objc func copy(_ sender: Any?) { copyHandler?() }

    override func keyDown(with event: NSEvent) {
        // delete / forward delete stage the selected rows for deletion
        if event.keyCode == 51 || event.keyCode == 117, !selectedRowIndexes.isEmpty {
            deleteHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Draws rows staged for deletion in red, including while selected.
final class MarkedRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MarkedRow")

    var isMarked = false {
        didSet {
            guard isMarked != oldValue else { return }
            needsDisplay = true
        }
    }

    var isDraft = false {
        didSet {
            guard isDraft != oldValue else { return }
            needsDisplay = true
        }
    }

    var isPinned = false {
        didSet {
            guard isPinned != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isDraft || isPinned {
            NSColor.systemGreen.withAlphaComponent(isDraft ? 0.16 : 0.1).setFill()
            dirtyRect.fill()
        }
        guard isMarked else { return }
        NSColor.systemRed.withAlphaComponent(0.22).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if isMarked {
            NSColor.systemRed.withAlphaComponent(0.4).setFill()
        } else if isEmphasized {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        } else {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        }
        path.fill()
    }
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
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderColor = NSColor.controlAccentColor.cgColor
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

    func show(_ value: String?, alignRight: Bool, showsLink: Bool, isInspected: Bool) {
        field.isEditable = false
        layer?.borderWidth = isInspected ? 1.5 : 0
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

    /// A cell of the blank row: empty means "use the column default".
    func showDraft(_ value: String?, alignRight: Bool) {
        field.isEditable = false
        field.alignment = alignRight ? .right : .left
        linkButton.isHidden = true
        fieldToButton.isActive = false
        fieldToEdge.isActive = true
        layer?.borderWidth = 0
        if let value {
            field.stringValue = value
            field.font = Self.font
            field.textColor = .labelColor
        } else {
            field.stringValue = "default"
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
