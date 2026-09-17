import SwiftUI

struct TableBrowserView: View {
    @Bindable var model: TableBrowserModel
    var onOpenRelation: (RelationRef, [ColumnFilter]) -> Void
    var onShowInspector: () -> Void
    @State private var showsPreview = false

    var body: some View {
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
            Divider()
            footer
        }
        .task { await model.start() }
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
        .padding(.horizontal, 10)
        .frame(height: 32)
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
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .opacity(model.isLoading ? 1 : 0)
                .frame(width: 14)
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red).lineLimit(1).help(error)
                Button("Dismiss") { model.error = nil }.buttonStyle(.link)
            } else {
                Text(model.readOnlyReason ?? "Double-click a cell to edit · right-click for more")
            }
            Spacer()
            if model.canEdit {
                Button { model.beginNewRow() } label: {
                    Label("Add Row", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(model.draftRow != nil)
                .help("Add a blank row at the bottom, then ⌘S to save")

                Button { model.markSelectedForDeletion() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(model.selectedRows.isEmpty)
                .help("Mark the selected rows for deletion (⌫)")
            }
            if let result = model.result {
                Text(rangeDescription(result)).monospacedDigit()
                Text(formatDuration(model.lastDuration)).monospacedDigit()
            }
            ControlGroup {
                Button { Task { await model.goToPage(model.page - 1) } } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page == 0 || model.isLoading)
                Button { Task { await model.goToPage(model.page + 1) } } label: { Image(systemName: "chevron.right") }
                    .disabled((model.result?.rowCount ?? 0) < model.pageSize || model.isLoading)
            }
            .fixedSize()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
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
