import AppKit
import SwiftUI

struct AssistantPanel: View {
    @Bindable var model: AssistantModel
    var onOpenSQL: (String) -> Void
    @FocusState private var composerFocused: Bool

    private let suggestions = [
        "What tables are there and how do they relate?",
        "Which tables have no primary key or missing indexes on foreign keys?",
        "Summarize the data in the table I have open",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.isClaudeInstalled {
                notInstalled
            } else if model.messages.isEmpty {
                emptyState
            } else {
                transcript
            }
            if let error = model.error {
                errorBanner(error)
            }
            composer
        }
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Claude").font(.headline)
            Text("Read-only")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quinary))
                .help("Claude can read schema and run queries in a read-only transaction. It can't change data.")
            Spacer()
            Button { model.newConversation() } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .disabled(model.messages.isEmpty && !model.isRunning)
            .help("New conversation")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tint)
            Text("Ask about \(model.databaseName)")
                .font(.title3.weight(.semibold))
            Text("Claude explores the schema and runs read-only queries using your Claude Code account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { model.send(suggestion) } label: {
                        Text(suggestion)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    private var notInstalled: some View {
        ContentUnavailableView {
            Label("Claude Code Not Found", systemImage: "sparkles")
        } description: {
            Text("Arsip uses your Claude Code subscription. Install Claude Code, run `claude` once in Terminal to sign in, then reopen this panel.")
        } actions: {
            Link("Get Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
        }
        .frame(maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { message in
                        MessageView(
                            message: message,
                            isStreaming: model.isRunning && message.id == model.messages.last?.id,
                            onOpenSQL: onOpenSQL
                        )
                    }
                    if model.isRunning, model.messages.last?.role == .user {
                        thinking
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: model.revision) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var thinking: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask about \(model.databaseName)…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit { model.send() }
                .padding(.vertical, 4)
            if model.isRunning {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (↩)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .strokeBorder(.quaternary)
        )
        .padding(10)
    }
}

private struct MessageView: View {
    let message: AssistantModel.Message
    let isStreaming: Bool
    let onOpenSQL: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            if case .text(_, let text) = message.blocks.first {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.blocks) { block in
                    switch block {
                    case .text(_, let text):
                        MarkdownView(text: text, onOpenSQL: onOpenSQL)
                    case .tool(let call):
                        ToolCallView(call: call, isRunning: isStreaming)
                    }
                }
                if isStreaming, message.blocks.isEmpty || message.blocks.last.map(isFinishedTool) == true {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func isFinishedTool(_ block: AssistantModel.Block) -> Bool {
        if case .tool(let call) = block { return call.output != nil }
        return false
    }
}

private struct ToolCallView: View {
    let call: AssistantModel.ToolCall
    let isRunning: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: call.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(call.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if call.name == "run_query" || call.name == "explain_query" {
                        Text(call.detail.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if call.output == nil, isRunning {
                        ProgressView().controlSize(.mini)
                    } else if call.isError {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if call.name == "run_query" || call.name == "explain_query" {
                    Text(call.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let output = call.output {
                    ScrollView(.horizontal) {
                        Text(output.count > 6000 ? String(output.prefix(6000)) + "\n…" : output)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(call.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary.opacity(0.7)))
    }
}

/// Small markdown renderer for chat replies: paragraphs with inline styling, headings,
/// bullet lists, tables and fenced code blocks.
private struct MarkdownView: View {
    let text: String
    let onOpenSQL: (String) -> Void

    private enum Part {
        case line(String)
        case table([[String]])
        case code(language: String, code: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .line(let line):
                    lineView(line)
                case .table(let rows):
                    tableView(rows)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code, onOpenSQL: onOpenSQL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var parts: [Part] {
        var parts: [Part] = []
        var code: (language: String, lines: [String])?
        var table: [[String]] = []

        func flushTable() {
            if !table.isEmpty { parts.append(.table(table)) }
            table = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    parts.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushTable()
                    code = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                }
            } else if code != nil {
                code?.lines.append(line)
            } else if trimmed.hasPrefix("|") {
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
                if !isSeparator { table.append(cells) }
            } else {
                flushTable()
                if !trimmed.isEmpty { parts.append(.line(line)) }
            }
        }
        flushTable()
        // A block still being streamed.
        if let open = code { parts.append(.code(language: open.language, code: open.lines.joined(separator: "\n"))) }
        return parts
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            Text(inline(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                .font(.headline)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(trimmed.dropFirst(2))))
            }
            .padding(.leading, CGFloat(line.prefix { $0 == " " }.count) * 4)
        } else {
            Text(inline(trimmed))
        }
    }

    private func tableView(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(index == 0 ? .callout.weight(.semibold) : .callout)
                                .lineLimit(3)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
        .textSelection(.enabled)
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    let onOpenSQL: (String) -> Void

    private var isSQL: Bool { language.isEmpty || language.lowercased() == "sql" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")
                if isSQL {
                    Button { onOpenSQL(code) } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open in a new query tab")
                }
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .frame(height: 30)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
    }
}
