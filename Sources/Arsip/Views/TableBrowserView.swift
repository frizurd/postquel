import SwiftUI

struct TableBrowserView: View {
    @Bindable var model: TableBrowserModel
    var onOpenRelation: (RelationRef, [ColumnFilter]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !model.filters.isEmpty {
                filterBar
                Divider()
            }
            ResultsGrid(
                result: model.result,
                sort: model.sort,
                sortable: true,
                editable: model.canEdit,
                linkColumns: model.linkColumns,
                onFollowLink: { row, column in
                    if let target = model.linkTarget(row: row, column: column) {
                        onOpenRelation(target.relation, target.filters)
                    }
                },
                onSort: { sort in Task { await model.applySort(sort) } },
                onEdit: { row, column, value in Task { await model.update(row: row, column: column, value: value) } }
            )
            Divider()
            footer
        }
        .task { await model.start() }
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
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red).lineLimit(1).help(error)
                Button("Dismiss") { model.error = nil }.buttonStyle(.link)
            } else {
                Text(model.readOnlyReason ?? "Double-click a cell to edit · right-click for more")
            }
            Spacer()
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
        return text
    }
}
