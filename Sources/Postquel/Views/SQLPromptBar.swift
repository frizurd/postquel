import AppKit
import SwiftUI

/// "Describe the query you want" bar above the SQL editor. Typing @ completes table names.
struct SQLPromptBar: View {
    @Bindable var generator: SQLGenerator
    let tables: [RelationRef]
    @Binding var request: String
    /// "Statement 2 of 3", when the editor holds more than one.
    var statementLabel: String?
    var onGenerate: () -> Void
    var onClose: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                MentionTextField(
                    text: $request,
                    placeholder: "Describe the query you want — type @ to reference a table",
                    completions: tables.map { $0.schema == "public" ? $0.name : "\($0.schema).\($0.name)" },
                    onSubmit: onGenerate,
                    onCancel: onClose
                )
                .focused($isFocused)
                .frame(height: 22)

                if generator.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { generator.cancel() }
                        .controlSize(.small)
                        .softButtonStyle()
                } else {
                    Button("Generate") { onGenerate() }
                        .controlSize(.small)
                        .softButtonStyle(prominent: true)
                        .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(TitlebarIconButtonStyle())
                .help("Close (esc)")
            }

            if let statementLabel {
                Label("Editing \(statementLabel.lowercased()) — it will be replaced", systemImage: "text.insert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = generator.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if let note = generator.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { isFocused = true }
    }
}

/// Single-line text field whose `@…` words complete from a list, using AppKit's own completion popup.
struct MentionTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var completions: [String]
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MentionTextView {
        let textView = MentionTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.string = text
        return textView
    }

    func updateNSView(_ textView: MentionTextView, context: Context) {
        context.coordinator.parent = self
        textView.completions = completions
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionTextField

        init(parent: MentionTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MentionTextView else { return }
            parent.text = textView.string
            textView.completeMentionIfNeeded()
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let mentionView = textView as? MentionTextView else { return [] }
            let partial = (textView.string as NSString).substring(with: charRange)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard !partial.isEmpty else { return mentionView.completions.map { "@\($0)" } }
            let matches = mentionView.completions.filter { $0.localizedCaseInsensitiveContains(partial) }
            return matches.sorted { lhs, rhs in
                let left = lhs.lowercased().hasPrefix(partial.lowercased())
                let right = rhs.lowercased().hasPrefix(partial.lowercased())
                return left == right ? lhs < rhs : left
            }.map { "@\($0)" }
        }
    }
}

final class MentionTextView: NSTextView {
    var completions: [String] = []
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var placeholder = ""

    /// The completion popup should cover the whole `@table.name` token.
    override var rangeForUserCompletion: NSRange {
        let text = string as NSString
        let caret = selectedRange().location
        var start = caret
        while start > 0 {
            let character = text.character(at: start - 1)
            guard let scalar = Unicode.Scalar(character) else { break }
            if scalar == "@" {
                start -= 1
                break
            }
            guard CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." else { return NSRange(location: NSNotFound, length: 0) }
            start -= 1
        }
        guard start < caret, text.character(at: start) == UInt16(UInt8(ascii: "@")) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: start, length: caret - start)
    }

    func completeMentionIfNeeded() {
        guard rangeForUserCompletion.location != NSNotFound else { return }
        complete(nil)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // Return submits (the completion popup handles it first when open); Escape closes the bar.
        if isReturn, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        if event.keyCode == 53 {  // escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 2, y: textContainerInset.height), withAttributes: attributes)
    }
}

extension String {
    /// The `name` part of every `@name` / `@schema.name` word.
    func mentionedNames() -> [String] {
        let text = self as NSString
        let pattern = try! NSRegularExpression(pattern: "@([A-Za-z0-9_.]+)")
        return pattern.matches(in: self, range: NSRange(location: 0, length: text.length)).map {
            text.substring(with: $0.range(at: 1))
        }
    }
}
