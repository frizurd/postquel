import AppKit
import SwiftUI

struct TableBrowserView: View {
    @Bindable var model: TableBrowserModel
    var onOpenRelation: (RelationRef, [ColumnFilter]) -> Void
    var onShowInspector: () -> Void
    /// Opens SQL in a new query tab (DDL view).
    var onOpenQuery: (String) -> Void = { _ in }
    @State private var showsPreview = false
    @State private var showsStructurePreview = false
    @State private var showsAddIndex = false
    /// Panes opened so far. They stay built while hidden, so switching back doesn't rebuild the grid.
    @State private var builtPanes: Set<TablePane> = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(TablePane.allCases) { pane in
                    if builtPanes.contains(pane) || pane == model.pane {
                        paneView(pane)
                            .inactive(pane != model.pane)
                    }
                }
            }
            Divider()
            footer
        }
        .onAppear { builtPanes.insert(model.pane) }
        .onChange(of: model.pane) { _, pane in builtPanes.insert(pane) }
        .task { await model.start() }
        .sheet(isPresented: $showsAddIndex) {
            AddIndexSheet(model: model.structure)
        }
        .confirmationDialog("Unsaved deletions", isPresented: $model.confirmingRefresh) {
            Button("Save Changes") { Task { await model.savePendingChanges() } }
            Button("Discard Changes", role: .destructive) {
                model.discardPendingChanges()
                Task { await model.reload() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.pendingSummary). Reloading discards unsaved changes.")
        }
    }

    @ViewBuilder
    private func paneView(_ pane: TablePane) -> some View {
        switch pane {
        case .content:
            contentPane
        case .structure:
            VStack(spacing: 0) {
                TableStructureView(model: model.structure)
                if model.structure.hasPendingChanges || model.structure.error != nil {
                    Divider()
                    structureChangesBar
                }
            }
        case .ddl:
            TableDDLView(model: model.structure)
        }
    }

    @ViewBuilder
    private var contentPane: some View {
        VStack(spacing: 0) {
            if !model.filters.isEmpty {
                filterBar
                Divider()
            }
            ResultsGrid(
                source: model.gridSource,
                sort: model.sort,
                sortable: true,
                editable: model.canEdit,
                linkColumns: model.linkColumns,
                selectedCell: model.selectedCell,
                onSelectCell: { model.selectedCell = $0 },
                markedRows: model.markedRows,
                pinnedRows: model.pinnedRowIndices,
                onSelectRows: { model.selectedRows = $0 },
                onDeleteRows: { model.markSelectedForDeletion() },
                draftValues: model.draftValues,
                onEditDraft: { column, value in model.setDraftValue(column: column, value: value) },
                onRequestInspector: onShowInspector,
                onFollowLink: { row, column in
                    if let target = model.linkTarget(row: row, column: column) {
                        onOpenRelation(target.relation, target.filters)
                    }
                },
                onSort: { sort in Task { await model.applySort(sort) } },
                onEdit: { row, column, value in Task { await model.update(row: row, column: column, value: value) } }
            )
            if model.hasPendingChanges {
                Divider()
                pendingChangesBar
            }
        }
    }

    /// Unsaved structure edits: what they amount to, the SQL, and Save / Discard.
    private var structureChangesBar: some View {
        let structure = model.structure
        return HStack(spacing: 8) {
            if let problem = structure.error ?? structure.validationError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(problem).foregroundStyle(.red).lineLimit(1).truncationMode(.tail).help(problem)
                    .textSelection(.enabled)
            } else {
                Image(systemName: "pencil.circle").foregroundStyle(.tint)
                Text(structure.pendingSummary)
            }
            if structure.isSaving { ProgressView().controlSize(.small) }
            Spacer()
            Button("Discard") { structure.discardChanges() }
                .disabled(!structure.hasPendingChanges)
            Button("SQL Preview") { showsStructurePreview = true }
                .disabled(!structure.hasPendingChanges)
                .popover(isPresented: $showsStructurePreview, arrowEdge: .top) {
                    ScrollView {
                        Text(structure.pendingPreview)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 520, height: 220)
                }
            Button("Save Changes") { Task { await structure.save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(!structure.hasPendingChanges || structure.validationError != nil)
                .help("Run the changes in one transaction (⌘S)")
        }
        .font(.callout)
        .controlSize(.small)
        .disabled(structure.isSaving)
        .padding(.horizontal, 12)
        .frame(height: Theme.barHeight)
        .background(Color.accentColor.opacity(0.08))
    }

    private var pendingChangesBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.pendingDeletions.isEmpty ? "plus.circle" : "trash")
                .foregroundStyle(model.pendingDeletions.isEmpty ? Color.green : Color.red)
            Text(model.pendingSummary)
            if model.isSaving { ProgressView().controlSize(.small) }
            Spacer()
            Button("Discard") { model.discardPendingChanges() }
            Button("SQL Preview") { showsPreview = true }
                .popover(isPresented: $showsPreview, arrowEdge: .top) {
                    ScrollView {
                        Text(model.pendingChangesPreview ?? "")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 460, height: 180)
                }
            Button("Save Changes") { Task { await model.savePendingChanges() } }
                .buttonStyle(.borderedProminent)
                .tint(model.pendingDeletions.isEmpty ? .accentColor : .red)
                .keyboardShortcut("s")
                .help("Delete the marked rows (⌘S)")
        }
        .font(.callout)
        .controlSize(.small)
        .disabled(model.isSaving)
        .padding(.horizontal, 12)
        .frame(height: Theme.barHeight)
        .background(Color.red.opacity(0.08))
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
            Text("WHERE").foregroundStyle(.secondary)
            Text(model.filterDescription).font(.system(.callout, design: .monospaced))
            Spacer()
            Button("Show All Rows") { Task { await model.clearFilters() } }
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: Theme.barHeight)
        .background(.bar)
    }

    /// Content / Structure / DDL on the left, then whatever the current view offers.
    private var footer: some View {
        HStack(spacing: 8) {
            GlassSegmentedPicker(selection: $model.pane, options: TablePane.allCases, title: \.title)
                .fixedSize()
                .help("Content, Structure or DDL of \(model.relation.name)")

            switch model.pane {
            case .content: contentFooter
            case .structure: structureFooter
            case .ddl: ddlFooter
            }
        }
        .bottomBar()
        .background {
            // ⌘1 / ⌘2 / ⌘3 switch views.
            ForEach(Array(TablePane.allCases.enumerated()), id: \.element) { index, pane in
                Button(pane.title) { model.pane = pane }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var contentFooter: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(model.isLoading ? 1 : 0)
            .frame(width: 14)
        if let error = model.error {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error).foregroundStyle(.red).lineLimit(1).help(error)
            Button("Dismiss") { model.error = nil }.buttonStyle(.link)
        } else if let reason = model.readOnlyReason {
            Label(reason, systemImage: "lock").lineLimit(1)
        }
        Spacer()
        if model.canEdit {
            Button { model.beginNewRow() } label: {
                Label("Add Row", systemImage: "plus")
            }
            .barButtonStyle()
            .disabled(model.draftRow != nil)
            .help("Add a blank row at the bottom, then ⌘S to save. Double-click a cell to edit it.")

            Button { model.markSelectedForDeletion() } label: {
                Label("Delete", systemImage: "trash")
            }
            .barButtonStyle()
            .disabled(model.selectedRows.isEmpty)
            .help("Mark the selected rows for deletion (⌫)")
        }
        if let result = model.result {
            Text(rangeDescription(result)).monospacedDigit()
            Text(formatDuration(model.lastDuration)).monospacedDigit()
        }
        HStack(spacing: 0) {
            Button { Task { await model.goToPage(model.page - 1) } } label: { Image(systemName: "chevron.left") }
                .disabled(model.page == 0 || model.isLoading)
                .help("Previous page")
            Button { Task { await model.goToPage(model.page + 1) } } label: { Image(systemName: "chevron.right") }
                .disabled((model.result?.rowCount ?? 0) < model.pageSize || model.isLoading)
                .help("Next page")
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .padding(2)
        .glassSurface(Capsule())
    }

    @ViewBuilder
    private var structureFooter: some View {
        let structure = model.structure
        ProgressView()
            .controlSize(.small)
            .opacity(structure.isLoading ? 1 : 0)
            .frame(width: 14)
        Text("\(structure.columns.count) columns · \(structure.indexes.count) indexes")
            .monospacedDigit()
            .opacity(structure.isLoaded ? 1 : 0)
        Spacer()
        if structure.isEditable {
            Button { structure.addColumn() } label: {
                Label("Add Column", systemImage: "plus")
            }
            .barButtonStyle()
            .disabled(!structure.isLoaded)
            .help("Add a column; it's created when you save")

            Button { showsAddIndex = true } label: {
                Label("Add Index…", systemImage: "list.bullet.indent")
            }
            .barButtonStyle()
            .disabled(!structure.isLoaded)
            .help("Add an index on one or more columns")
        }
    }

    @ViewBuilder
    private var ddlFooter: some View {
        Text(model.structure.hasPendingChanges ? "Includes unsaved changes at the end" : "SQL to recreate \(model.relation.name)")
            .lineLimit(1)
        Spacer()
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.structure.ddl, forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .barButtonStyle()
        .disabled(!model.structure.isLoaded)
        Button { onOpenQuery(model.structure.ddl) } label: {
            Label("Open in Query Tab", systemImage: "arrow.up.right.square")
        }
        .barButtonStyle()
        .disabled(!model.structure.isLoaded)
    }

    private func rangeDescription(_ result: PGResult) -> String {
        guard result.rowCount > 0 else { return "No rows" }
        let start = model.page * model.pageSize
        var text = "Rows \((start + 1).formatted())–\((start + result.rowCount).formatted())"
        if model.filters.isEmpty, let estimate = model.estimatedRows, estimate > 0 { text += " of ~\(estimate.formatted())" }
        let pinned = model.pinnedRowIndices.count
        if pinned > 0 { text += " · \(pinned) added below" }
        return text
    }
}
