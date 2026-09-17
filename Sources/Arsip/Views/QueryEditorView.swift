import SwiftUI

struct QueryEditorView: View {
    @Bindable var model: QueryEditorModel
    var onShowInspector: () -> Void

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                editorBar
                Divider()
                SQLEditor(
                    text: $model.text,
                    onSelectionChange: { model.selectedText = $0 },
                    onRun: { Task { await model.runCurrent() } }
                )
            }
            .frame(minHeight: 120, idealHeight: 260)

            resultsPane
                .frame(minHeight: 140)
        }
        .onChange(of: model.text) { model.onTextChange?() }
    }

    private var editorBar: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                Button(role: .destructive) { model.cancel() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.runCurrent() } } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .help("Run selection, or the whole editor (⌘↩)")
            }
            Text("⌘↩ runs the selection or everything")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    @ViewBuilder
    private var resultsPane: some View {
        VStack(spacing: 0) {
            if model.rowResultIndices.count > 1 {
                Picker("Result", selection: $model.selectedResultIndex) {
                    ForEach(model.rowResultIndices, id: \.self) { index in
                        Text("Result \(index + 1)").tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(6)
                Divider()
            }

            if let rows = model.currentResult?.rows {
                ResultsGrid(
                    result: rows,
                    selectedCell: model.selectedCell,
                    onSelectCell: { model.selectedCell = $0 },
                    onRequestInspector: onShowInspector
                )
            } else if let error = model.error, model.results.isEmpty {
                ScrollView {
                    Text(error)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else if !model.results.isEmpty {
                List(model.results) { result in
                    Text(result.status).font(.system(.body, design: .monospaced))
                }
            } else {
                ContentUnavailableView("No Results", systemImage: "tablecells", description: Text("Write a query and press ⌘↩"))
            }

            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = model.error, !model.results.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red).lineLimit(1).truncationMode(.tail).help(error)
            } else if let result = model.currentResult {
                Text(result.rows.map { rowCountText($0.rowCount) } ?? result.status)
            }
            Spacer()
            if let duration = model.duration {
                Text(formatDuration(duration)).monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

func rowCountText(_ count: Int) -> String {
    count == 1 ? "1 row" : "\(count.formatted()) rows"
}

func formatDuration(_ seconds: TimeInterval) -> String {
    seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
}
