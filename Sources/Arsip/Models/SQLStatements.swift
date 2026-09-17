import Foundation

/// Splits editor text into individual statements so Arsip can run exactly one.
/// Semicolons inside strings, quoted identifiers, dollar-quoted bodies and comments don't split.
enum SQLStatements {
    /// Ranges of each statement, without the trailing semicolon, ignoring blank/comment-only pieces.
    static func ranges(in sql: String) -> [NSRange] {
        let characters = Array(sql)
        var ranges: [NSRange] = []
        var start = 0
        var index = 0

        func appendStatement(end: Int) {
            if let range = statementRange(characters, from: start, to: end) { ranges.append(range) }
        }

        while index < characters.count {
            switch characters[index] {
            case "'", "\"":
                index = endOfQuoted(characters, from: index, quote: characters[index])
            case "$":
                if let tagEnd = dollarTagEnd(characters, from: index) {
                    index = endOfDollarQuoted(characters, from: index, tagLength: tagEnd - index)
                } else {
                    index += 1
                }
            case "-" where index + 1 < characters.count && characters[index + 1] == "-":
                while index < characters.count, characters[index] != "\n" { index += 1 }
            case "/" where index + 1 < characters.count && characters[index + 1] == "*":
                index = endOfBlockComment(characters, from: index)
            case ";":
                appendStatement(end: index)
                index += 1
                start = index
            default:
                index += 1
            }
        }
        appendStatement(end: characters.count)
        return ranges
    }

    /// The statement a caret or selection points at: what ⌘↩ runs and what the AI bar edits.
    struct Active: Equatable {
        var range: NSRange
        /// Position in the document, used to keep one AI draft per statement.
        var index: Int
        /// How many statements the selection covers; more than one means only the first runs.
        var selectedCount: Int
    }

    static func active(in sql: String, for selection: NSRange) -> Active? {
        let all = ranges(in: sql)
        guard !all.isEmpty else { return nil }

        if selection.length > 0 {
            let selected = all.indices.filter { NSIntersectionRange(all[$0], selection).length > 0 }
            guard let first = selected.first else { return nil }
            // A partial selection runs exactly what's selected.
            if selected.count == 1, !NSEqualRanges(NSIntersectionRange(all[first], selection), all[first]) {
                return Active(range: NSIntersectionRange(all[first], selection), index: first, selectedCount: 1)
            }
            return Active(range: all[first], index: first, selectedCount: selected.count)
        }

        let caret = selection.location
        if let index = all.indices.first(where: { caret >= all[$0].location && caret <= all[$0].upperBound }) {
            return Active(range: all[index], index: index, selectedCount: 1)
        }
        if let index = all.indices.last(where: { all[$0].upperBound < caret }) {
            return Active(range: all[index], index: index, selectedCount: 1)
        }
        return Active(range: all[0], index: 0, selectedCount: 1)
    }

    // MARK: Scanning helpers

    private static func endOfQuoted(_ characters: [Character], from index: Int, quote: Character) -> Int {
        var index = index + 1
        while index < characters.count {
            if characters[index] == quote {
                // Doubled quote is an escaped quote, not the end.
                if index + 1 < characters.count, characters[index + 1] == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            if quote == "'", characters[index] == "\\", index + 1 < characters.count {
                index += 2  // backslash escapes, for standard_conforming_strings = off
                continue
            }
            index += 1
        }
        return index
    }

    /// End index of the opening `$tag$`, or nil when this `$` doesn't start a dollar quote.
    private static func dollarTagEnd(_ characters: [Character], from index: Int) -> Int? {
        var cursor = index + 1
        while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "$" else { return nil }
        return cursor + 1
    }

    private static func endOfDollarQuoted(_ characters: [Character], from index: Int, tagLength: Int) -> Int {
        let tag = Array(characters[index..<(index + tagLength)])
        var cursor = index + tagLength
        while cursor + tag.count <= characters.count {
            if Array(characters[cursor..<(cursor + tag.count)]) == tag { return cursor + tag.count }
            cursor += 1
        }
        return characters.count
    }

    private static func endOfBlockComment(_ characters: [Character], from index: Int) -> Int {
        var cursor = index + 2
        var depth = 1  // PostgreSQL nests block comments
        while cursor + 1 < characters.count {
            if characters[cursor] == "/" && characters[cursor + 1] == "*" {
                depth += 1
                cursor += 2
            } else if characters[cursor] == "*" && characters[cursor + 1] == "/" {
                depth -= 1
                cursor += 2
                if depth == 0 { return cursor }
            } else {
                cursor += 1
            }
        }
        return characters.count
    }

    /// Trims whitespace, drops comment-only pieces, and converts character offsets to a UTF-16 range.
    private static func statementRange(_ characters: [Character], from start: Int, to end: Int) -> NSRange? {
        var first = start, last = end
        while first < last, characters[first].isWhitespace { first += 1 }
        while last > first, characters[last - 1].isWhitespace { last -= 1 }
        guard first < last, hasCode(Array(characters[first..<last])) else { return nil }
        let location = String(characters[0..<first]).utf16.count
        let length = String(characters[first..<last]).utf16.count
        return NSRange(location: location, length: length)
    }

    /// False for pieces that contain only comments.
    private static func hasCode(_ text: [Character]) -> Bool {
        var index = 0
        while index < text.count {
            if text[index] == "-", index + 1 < text.count, text[index + 1] == "-" {
                while index < text.count, text[index] != "\n" { index += 1 }
            } else if text[index] == "/", index + 1 < text.count, text[index + 1] == "*" {
                index = endOfBlockComment(text, from: index)
            } else if text[index].isWhitespace {
                index += 1
            } else {
                return true
            }
        }
        return false
    }
}
