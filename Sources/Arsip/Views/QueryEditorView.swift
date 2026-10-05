import SwiftUI

struct QueryEditorView: View {
    @Bindable var model: QueryEditorModel
    var generator: SQLGenerator?
    var tables: [RelationRef] = []
    var onShowInspector: () -> Void
    /// Hands a prompt to the assistant panel and opens it.
    var onAskAssistant: ((String) -> Void)? = nil
    /// Names an unsaved query so it joins this database's list.
    var onSaveQuery: ((String) -> Void)? = nil
    @State private var showsSaveQuery = false
    @State private var showsPrompt = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                if let generator, showsPrompt {
                    SQLPromptBar(
                        generator: generator,
                        tables: tables,
                        request: $model.promptDraft,
                        statementLabel: statementLabel,
                        onGenerate: { generate(with: generator) },
                        onClose: { showsPrompt = false }
                    )
                    .padding([.horizontal, .top], 8)
                    .padding(.bottom, 2)
                    .background(Color(nsColor: .textBackgroundColor))
                }
                ZStack(alignment: .bottomTrailing) {
                    SQLEditor(
                        text: $model.text,
                        activeRange: model.active?.range,
                        onSelectionChange: { model.updateSelection(range: $0) },
                        onRun: { Task { await model.runCurrent() } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    runControl
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
            .frame(minHeight: 160, idealHeight: 280)


            resultsPane
                .frame(minHeight: 140)
        }
        .sheet(isPresented: $showsSaveQuery) {
            SaveQuerySheet { onSaveQuery?($0) }
        }
        .onChange(of: model.text) {
            model.refreshActiveStatement()
            model.onTextChange?()
        }
    }

    /// "Statement 2 of 3" while there's more than one.
    private var statementLabel: String? {
        guard let active = model.active else { return nil }
        let total = SQLStatements.ranges(in: model.text).count
        return total > 1 ? "Statement \(active.index + 1) of \(total)" : nil
    }

    private func generate(with generator: SQLGenerator) {
        let request = model.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !generator.isRunning else { return }
        // "@public.orders" / "@orders" reference tables; send the names along, without the @.
        let mentions = request.mentionedNames()
        let resolved = mentions.compactMap { mention in
            tables.first { $0.name == mention || "\($0.schema).\($0.name)" == mention }
        }.map { "\($0.schema).\($0.name)" }
        let plain = request.replacingOccurrences(of: "@", with: "")

        Task {
            if let sql = await generator.generate(request: plain, currentSQL: model.activeStatementText ?? "",
                                                  mentionedTables: Array(Set(resolved)).sorted()) {
                model.applyGenerated(sql)
            }
        }
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

            if let rows = model.displayedRows {
                ResultsGrid(
                    source: rows,
                    sort: model.resultSort,
                    sortable: true,
                    selectedCell: model.selectedCell,
                    onSelectCell: { model.selectedCell = $0 },
                    onRequestInspector: onShowInspector,
                    onSort: { model.resultSort = $0 }
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

    /// Everything the editor needs, floating over its bottom-right corner.
    private var runControl: some View {
        HStack(spacing: 8) {
            if let label = statementLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .glassLabel()
            }
            if generator != nil {
                Button { showsPrompt.toggle() } label: {
                    Label("Ask AI", systemImage: "sparkles")
                }
                .softButtonStyle()
                .keyboardShortcut("l")
                .help("Describe the query you want (⌘L)")
            }
            if let name = model.name {
                Label(name, systemImage: "text.alignleft")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .glassLabel()
            } else if onSaveQuery != nil {
                Button { showsSaveQuery = true } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .softButtonStyle()
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Keep this query in the sidebar for this database")
            }
            Button {
                if model.isRunning {
                    model.cancel()
                } else {
                    Task { await model.runCurrent() }
                }
            } label: {
                Label(model.isRunning ? "Cancel" : "Run", systemImage: model.isRunning ? "stop.fill" : "play.fill")
            }
            .softButtonStyle(prominent: !model.isRunning)
            .help(model.isRunning ? "Cancel the running query" : "Run the statement at the cursor (⌘↩)")
        }
        .modifier(RunControlSurface())
    }

    @ViewBuilder
    private func speedBadge(_ duration: TimeInterval) -> some View {
        let speed = QuerySpeed(duration: duration, failed: model.error != nil)
        HStack(spacing: 6) {
            if speed == .slow, let sql = model.lastRunSQL, onAskAssistant != nil {
                Button {
                    onAskAssistant?(Self.slowQueryPrompt(sql: sql, duration: duration))
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .barButtonStyle()
                .help("Ask the assistant why this is slow")
            }
            Label {
                Text(formatDuration(duration)).monospacedDigit()
            } icon: {
                Image(systemName: speed.symbol)
            }
            .foregroundStyle(speed.color)
            .help(speed.explanation)
        }
    }

    private static func slowQueryPrompt(sql: String, duration: TimeInterval) -> String {
        """
        This query took \(formatDuration(duration)) in Arsip:

        ```sql
        \(sql)
        ```

        Run explain_query with analyze=true, say in one or two sentences where the time goes,         and suggest the specific fixes worth making (indexes with the exact CREATE INDEX, or a         rewrite). Check the table sizes and existing indexes before suggesting one.
        """
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = model.error, !model.results.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red).lineLimit(1).truncationMode(.tail).help(error)
            } else if let result = model.currentResult {
                Text(result.rows.map { rowCountText($0.rowCount) } ?? result.status)
                if let note = model.lastRunNote {
                    Text("· \(note)")
                }
            }
            Spacer()
            if model.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(formatDuration(model.elapsed)).monospacedDigit()
                }
            } else if let duration = model.duration {
                speedBadge(duration)
            }
        }
        .bottomBar()
    }
}

/// On macOS 26 each run control is its own piece of glass, blended by a container. Before that,
/// they share one floating material panel.
private struct RunControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassGroup(spacing: 8)
        } else {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}

private extension View {
    /// Plain text in a glass capsule on macOS 26, so it reads over the editor like the buttons beside it.
    @ViewBuilder
    func glassLabel() -> some View {
        if #available(macOS 26, *) {
            padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
        } else {
            self
        }
    }
}

func rowCountText(_ count: Int) -> String {
    count == 1 ? "1 row" : "\(count.formatted()) rows"
}

func formatDuration(_ seconds: TimeInterval) -> String {
    seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
}

private struct SaveQuerySheet: View {
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Query").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Saved queries live in the sidebar of this database only.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
