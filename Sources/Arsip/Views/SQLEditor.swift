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

    func makeNSView(context: Context) -> EditorContainer {
        let container = EditorContainer()
        let scroll = container.scroll
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
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
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
        if let storage = textView.textStorage { SQLHighlighter.highlight(storage, active: activeRange) }

        scroll.documentView = textView
        container.attach(textView)
        return container
    }

    func updateNSView(_ container: EditorContainer, context: Context) {
        context.coordinator.parent = self
        container.gutter.needsDisplay = true
        guard let textView = container.scroll.documentView as? SQLTextView else { return }
        if context.coordinator.activeRange != activeRange {
            context.coordinator.activeRange = activeRange
            if let storage = textView.textStorage { SQLHighlighter.highlight(storage, active: activeRange) }
        }
        guard textView.string != text else {
            if let storage = textView.textStorage, storage.length > 0 {
                // Cheap insurance: colors can be lost if something replaced the storage's attributes.
                SQLHighlighter.highlight(storage, active: activeRange)
            }
            return
        }
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
    /// Re-applies colors; the coordinator sets this up.
    var rehighlight: (() -> Void)?
    weak var gutter: GutterView?

    override func didChangeText() {
        super.didChangeText()
        gutter?.needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        gutter?.needsDisplay = true
    }

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

/// The editor and its line numbers side by side. The numbers are a plain sibling view rather than
/// an NSRulerView: a ruler inside the scroll view stopped the text view drawing and taking input.
final class EditorContainer: NSView {
    let scroll = NSScrollView()
    let gutter = GutterView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(gutter)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func attach(_ textView: SQLTextView) {
        gutter.textView = textView
        textView.gutter = gutter
        // Redraw the numbers while scrolling.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak gutter] _ in
            MainActor.assumeIsolated { gutter?.needsDisplay = true }
        }
    }

    override func layout() {
        super.layout()
        let width = gutter.preferredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(bounds.width - width, 0), height: bounds.height)
    }
}

/// Draws line numbers for the editor next to it, with the cursor's line at full contrast.
final class GutterView: NSView {
    weak var textView: SQLTextView?
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat {
        let lines = max((textView?.string as NSString?)?.lineCount ?? 1, 1)
        return max(34, CGFloat("\(lines)".count) * 7 + 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return }
        let text = textView.string as NSString
        let inset = textView.textContainerInset.height
        let visible = textView.visibleRect
        let cursorLine = text.lineNumber(at: textView.selectedRange().location)
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? SQLHighlighter.font)

        func drawNumber(_ line: Int, atTextY y: CGFloat, height: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: line == cursorLine ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ]
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let gutterY = y + inset - visible.minY + (height - size.height) / 2
            guard gutterY > -height, gutterY < bounds.height else { return }
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: gutterY), withAttributes: attributes)
        }

        guard text.length > 0 else {
            drawNumber(1, atTextY: 0, height: lineHeight)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var index = text.paragraphStart(of: charRange.location)
        var line = text.lineNumber(at: index)

        while index < text.length, index <= charRange.upperBound {
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index),
                                                          effectiveRange: nil, withoutAdditionalLayout: false)
            drawNumber(line, atTextY: fragment.minY, height: fragment.height)

            var paragraphEnd = 0
            text.getParagraphStart(nil, end: &paragraphEnd, contentsEnd: nil, for: NSRange(location: index, length: 0))
            guard paragraphEnd > index else { break }
            index = paragraphEnd
            line += 1
        }
        // A trailing newline leaves one more, empty, line.
        if text.character(at: text.length - 1) == 0x0A, charRange.upperBound >= text.length {
            let fragment = layoutManager.extraLineFragmentRect
            drawNumber(line, atTextY: fragment.minY, height: fragment.height > 0 ? fragment.height : lineHeight)
        }
    }
}

private extension NSString {
    var lineCount: Int {
        var lines = 1
        enumerateSubstrings(in: NSRange(location: 0, length: length), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lines += 1
        }
        return lines
    }

    func lineNumber(at location: Int) -> Int {
        guard location > 0, length > 0 else { return 1 }
        var line = 1
        enumerateSubstrings(in: NSRange(location: 0, length: min(location, length)),
                            options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        return line
    }

    func paragraphStart(of location: Int) -> Int {
        var start = 0
        getParagraphStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: min(location, length), length: 0))
        return start
    }
}
