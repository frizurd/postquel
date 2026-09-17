import AppKit
import SwiftUI

enum InspectorMode: String {
    case value, assistant
}

/// Right-hand inspector: the selected cell's value, or the Claude assistant.
struct InspectorPanel: View {
    let session: SessionModel
    @Binding var mode: InspectorMode

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $mode) {
                Text("Value").tag(InspectorMode.value)
                Text("Assistant").tag(InspectorMode.assistant)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch mode {
            case .value:
                valueContent
            case .assistant:
                if let assistant = session.assistant {
                    AssistantPanel(model: assistant, onOpenSQL: { session.openQueryTab(text: $0) })
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var valueContent: some View {
        switch session.activeTab?.content {
        case .table(let browser):
            if let result = browser.gridSource, let cell = browser.selectedCell, contains(result, cell) {
                CellEditor(source: result, cell: cell, isEditable: browser.canEdit) { value in
                    Task { await browser.update(row: cell.row, column: cell.column, value: value) }
                }
                // Fresh drafts whenever the cell or the loaded result changes (e.g. after saving).
                .id(EditorIdentity(result: ObjectIdentifier(result), cell: cell))
            } else {
                placeholder
            }
        case .query(let editor):
            if let result = editor.currentResult?.rows, let cell = editor.selectedCell, contains(result, cell) {
                CellEditor(source: result, cell: cell, isEditable: false, onSave: { _ in })
                    .id(EditorIdentity(result: ObjectIdentifier(result), cell: cell))
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("No Cell Selected", systemImage: "square.and.pencil",
                               description: Text("Click a cell to view or edit its value"))
    }

    private func contains(_ result: GridSource, _ cell: CellSelection) -> Bool {
        cell.row < result.rowCount && cell.column < result.columns.count
    }

    private struct EditorIdentity: Hashable {
        let result: ObjectIdentifier
        let cell: CellSelection
    }
}

struct CellEditor: View {
    let column: PGColumn
    let cell: CellSelection
    let isEditable: Bool
    let onSave: (String?) -> Void

    private let initialText: String
    private let initialNull: Bool
    @State private var text: String
    @State private var isNull: Bool

    init(source: GridSource, cell: CellSelection, isEditable: Bool, onSave: @escaping (String?) -> Void) {
        let column = source.columns[cell.column]
        let value = source.value(row: cell.row, column: cell.column)
        let shown = value.map { column.isJSON ? JSONFormatter.pretty($0) : $0 } ?? ""
        self.column = column
        self.cell = cell
        self.isEditable = isEditable
        self.onSave = onSave
        initialText = shown
        initialNull = value == nil
        _text = State(initialValue: shown)
        _isNull = State(initialValue: value == nil)
    }

    private var isDirty: Bool {
        isNull != initialNull || (!isNull && text != initialText)
    }

    /// nil when the value isn't JSON or is valid.
    private var jsonError: String? {
        guard column.isJSON, !isNull else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
            return nil
        } catch {
            return "Invalid JSON"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            editor
            statusLine
            Divider()
            actions
        }
        .padding(14)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(column.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(column.typeName) · row \(cell.row + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isEditable {
                Text("Read-only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quinary))
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if column.isBool {
            Picker("Value", selection: $text) {
                Text("true").tag("t")
                Text("false").tag("f")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!isEditable || isNull)
            Spacer()
        } else {
            PlainTextEditor(
                text: $text,
                font: column.isJSON
                    ? .monospacedSystemFont(ofSize: 12, weight: .regular)
                    : .systemFont(ofSize: 13),
                isEditable: isEditable && !isNull
            )
            .opacity(isNull ? 0.35 : 1)
            .overlay {
                if isNull {
                    Text("NULL").font(.title3.italic()).foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let jsonError {
                Label(jsonError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if column.isJSON, !isNull {
                Label("Valid JSON", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            if !isNull, !column.isBool {
                Text("\(text.count.formatted()) characters").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.caption)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if isEditable {
                Toggle("NULL", isOn: $isNull).toggleStyle(.checkbox)
            }
            if column.isJSON, isEditable, !isNull {
                Button("Format") { text = JSONFormatter.pretty(text) }
                    .disabled(jsonError != nil)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(isNull ? "NULL" : text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy value")

            Spacer()

            if isEditable {
                Button("Revert") {
                    text = initialText
                    isNull = initialNull
                }
                .disabled(!isDirty)

                Button("Save") { onSave(isNull ? nil : text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
                    .disabled(!isDirty || jsonError != nil)
                    .help("Save to the database (⌘S)")
            }
        }
        .controlSize(.regular)
    }
}

/// NSTextView without smart quotes/dashes/autocorrect, which would corrupt JSON and code.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.delegate = context.coordinator
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        if textView.font != font { textView.font = font }
        textView.textColor = .labelColor
        textView.isEditable = isEditable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor

        init(parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// Re-indents JSON text without parsing it, so numbers and key order stay exactly as stored.
enum JSONFormatter {
    static func pretty(_ json: String, indent: String = "  ") -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return json }

        let chars = Array(trimmed)
        var output = ""
        var level = 0
        var inString = false
        var escaped = false
        var index = 0

        func newline() {
            output += "\n" + String(repeating: indent, count: level)
        }

        while index < chars.count {
            let char = chars[index]
            if inString {
                output.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"":
                    inString = true
                    output.append(char)
                case "{", "[":
                    let closing: Character = char == "{" ? "}" : "]"
                    var next = index + 1
                    while next < chars.count, chars[next].isWhitespace { next += 1 }
                    if next < chars.count, chars[next] == closing {
                        output += String([char, closing])  // keep {} and [] inline
                        index = next
                    } else {
                        output.append(char)
                        level += 1
                        newline()
                    }
                case "}", "]":
                    level = max(0, level - 1)
                    newline()
                    output.append(char)
                case ",":
                    output.append(char)
                    newline()
                case ":":
                    output += ": "
                default:
                    if !char.isWhitespace { output.append(char) }
                }
            }
            index += 1
        }
        return output
    }
}
