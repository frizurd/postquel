import AppKit
import SwiftUI

/// Plain NSTextView with SQL highlighting and ⌘↩ to run.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    /// Statement to keep at full contrast; everything else is dimmed.
    var activeRange: NSRange?
    var onSelectionChange: (NSRange) -> Void
    var onRun: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = SQLTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = SQLHighlighter.font
        textView.typingAttributes = [.font: SQLHighlighter.font, .foregroundColor: NSColor.labelColor]

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.onRun = { [weak coordinator = context.coordinator] in coordinator?.parent.onRun() }
        textView.string = text

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SQLTextView else { return }
        if context.coordinator.activeRange != activeRange {
            context.coordinator.activeRange = activeRange
            if let storage = textView.textStorage { SQLHighlighter.highlight(storage, active: activeRange) }
        }
        guard textView.string != text else { return }
        // Replace through the text storage so generated SQL can be undone with ⌘Z.
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: whole, replacementString: text) {
            textView.textStorage?.replaceCharacters(in: whole, with: text)
            textView.didChangeText()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: SQLEditor
        var activeRange: NSRange?
        weak var textView: SQLTextView?

        init(parent: SQLEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onSelectionChange(textView.selectedRange())
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            SQLHighlighter.highlight(textStorage, active: activeRange)
        }
    }
}

final class SQLTextView: NSTextView {
    var onRun: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           window?.firstResponder === self {
            onRun?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Carry the current line's indentation onto the new line.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let indent = text.substring(with: lineRange).prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}

enum SQLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static let keywords = """
        select from where and or not in is null as on join left right inner outer full cross natural using \
        group by order having limit offset union all intersect except distinct insert into values update set \
        delete returning create alter drop table view index schema database sequence function procedure trigger \
        extension materialized if exists primary key foreign references unique check default constraint cascade \
        restrict begin commit rollback transaction savepoint with recursive case when then else end cast \
        like ilike between asc desc nulls first last true false explain analyze verbose grant revoke to \
        lateral over partition window filter do language returns replace truncate vacuum copy
        """
        .split(whereSeparator: \.isWhitespace).joined(separator: "|")

    private static let rules: [(NSRegularExpression, NSColor)] = [
        (regex("\\b\\d+(\\.\\d+)?\\b"), .systemBlue),
        (regex("\\b(\(keywords))\\b", options: .caseInsensitive), .systemPink),
        (regex("\"(?:[^\"]|\"\")*\"?"), .systemTeal),
        (regex("'(?:[^']|'')*'?"), .systemOrange),
        (regex("--[^\\n]*"), .secondaryLabelColor),
        (regex("/\\*[\\s\\S]*?(?:\\*/|$)"), .secondaryLabelColor),
    ]

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func highlight(_ storage: NSTextStorage, active: NSRange? = nil) {
        let full = NSRange(location: 0, length: storage.length)
        // Colors only: overriding the font would break glyph fallback (e.g. ⌘ ↩ in comments).
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        // Later rules win, so strings and comments override keywords inside them.
        for (regex, color) in rules {
            regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        // Dim everything outside the statement that ⌘↩ would run.
        guard let active, active.upperBound <= storage.length else { return }
        for range in [NSRange(location: 0, length: active.location),
                      NSRange(location: active.upperBound, length: storage.length - active.upperBound)]
        where range.length > 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }
}
