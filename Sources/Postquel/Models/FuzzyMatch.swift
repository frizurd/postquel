import Foundation

/// Subsequence matching with bonuses for matches at word starts and runs of adjacent characters.
struct FuzzyMatch<Value> {
    let value: Value
    let score: Int
    let highlighted: AttributedString

    static func rank(_ values: [Value], query: String, text: (Value) -> String) -> [FuzzyMatch<Value>] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            return values.map { FuzzyMatch(value: $0, score: 0, highlighted: AttributedString(text($0))) }
        }
        return values.compactMap { value -> FuzzyMatch<Value>? in
            let target = text(value)
            guard let (score, matched) = best(query: Array(query), target: Array(target.lowercased())) else { return nil }
            return FuzzyMatch(value: value, score: score, highlighted: highlight(target, matched: matched))
        }
        .sorted { $0.score > $1.score }
    }

    /// Greedy matching takes the first occurrence, which misses better matches further along
    /// ("cust" should hit customers, not the c in public). Try every start and keep the best.
    private static func best(query: [Character], target: [Character]) -> (Int, Set<Int>)? {
        guard let first = query.first else { return nil }
        var best: (Int, Set<Int>)?
        for start in target.indices where target[start] == first {
            guard let candidate = score(query: query, target: target, from: start) else { continue }
            if candidate.0 > (best?.0 ?? Int.min) { best = candidate }
        }
        return best
    }

    private static func score(query: [Character], target: [Character], from start: Int) -> (Int, Set<Int>)? {
        var matched: Set<Int> = []
        var score = 0
        var targetIndex = start
        var previousMatch = -2

        for character in query {
            var found: Int?
            while targetIndex < target.count {
                if target[targetIndex] == character {
                    found = targetIndex
                    break
                }
                targetIndex += 1
            }
            guard let index = found else { return nil }
            matched.insert(index)
            score += 1
            if index == previousMatch + 1 { score += 8 }  // contiguous
            if index == 0 || target[index - 1] == "." || target[index - 1] == "_" { score += 10 }  // word start
            previousMatch = index
            targetIndex = index + 1
        }
        return (score - target.count / 8, matched)
    }

    private static func highlight(_ text: String, matched: Set<Int>) -> AttributedString {
        var result = AttributedString()
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(index) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
        }
        return result
    }
}
