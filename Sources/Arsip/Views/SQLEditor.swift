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
        textView.rehighlight = { [weak coordinator = context.coordinator, weak textView] in
            guard let storage = textView?.textStorage else { return }
            SQLHighlighter.highlight(storage, active: coordinator?.activeRange)
        }
        textView.string = text

        scroll.documentView = textView

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        textView.lineNumbers = ruler

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
    weak var lineNumbers: LineNumberRuler?

    override func didChangeText() {
        super.didChangeText()
        lineNumbers?.needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        lineNumbers?.needsDisplay = true
    }
    /// Re-applies colors; the coordinator sets this up.
    var rehighlight: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Colors can end up stale after the app sits in the background (appearance changes, window
        // moving between spaces or screens), so re-apply them whenever the view comes back into use.
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeBackingPropertiesNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rehighlight?() }
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rehighlight?() }
        }
        rehighlight?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rehighlight?()
    }

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
        // Dim everything outside the statement that ⌘↩ would run. Clamp rather than skip: a stale
        // range would otherwise leave the previous dimming in place.
        guard let active, active.location <= storage.length else { return }
        let end = min(active.upperBound, storage.length)
        for range in [NSRange(location: 0, length: active.location),
                      NSRange(location: end, length: storage.length - end)]
        where range.length > 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }
}

/// Line numbers down the left of the editor, like an IDE. The line the cursor is on stands out.
final class LineNumberRuler: NSRulerView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        // Redraw while scrolling.
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Drawn in full: the default ruler paints a border down its edge, which ran past the
    /// editor and into the bar above it.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let text = textView.string as NSString
        let inset = textView.textContainerInset.height
        let cursorLine = lineNumber(at: textView.selectedRange().location, in: text)

        /// Line fragment positions are in the text view; the ruler scrolls with it.
        func rulerY(_ fragmentMinY: CGFloat) -> CGFloat {
            convert(NSPoint(x: 0, y: fragmentMinY + inset), from: textView).y
        }

        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? SQLHighlighter.font)
        guard text.length > 0 else {
            draw(line: 1, at: rulerY(0), isCurrent: true, height: lineHeight)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var index = paragraphStart(of: charRange.location, in: text)
        var line = lineNumber(at: index, in: text)
        while index < text.length, index <= charRange.upperBound {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil,
                                                          withoutAdditionalLayout: false)
            draw(line: line, at: rulerY(fragment.minY), isCurrent: line == cursorLine, height: fragment.height)

            var paragraphEnd = 0
            text.getParagraphStart(nil, end: &paragraphEnd, contentsEnd: nil, for: NSRange(location: index, length: 0))
            guard paragraphEnd > index else { break }
            index = paragraphEnd
            line += 1
        }

        // A trailing newline leaves one more (empty) line with no glyphs of its own.
        if text.character(at: text.length - 1) == 0x0A, charRange.upperBound >= text.length {
            let fragment = layoutManager.extraLineFragmentRect
            draw(line: line, at: rulerY(fragment.minY), isCurrent: line == cursorLine,
                 height: fragment.height > 0 ? fragment.height : lineHeight)
        }
    }

    private func paragraphStart(of location: Int, in text: NSString) -> Int {
        var start = 0
        text.getParagraphStart(&start, end: nil, contentsEnd: nil,
                               for: NSRange(location: min(location, text.length), length: 0))
        return start
    }

    private func draw(line: Int, at y: CGFloat, isCurrent: Bool, height: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ]
        let label = "\(line)" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (height - size.height) / 2),
                   withAttributes: attributes)
    }

    /// 1-based line number of a character offset.
    private func lineNumber(at location: Int, in text: NSString) -> Int {
        guard location > 0, text.length > 0 else { return 1 }
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: min(location, text.length)),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        return line
    }
}
