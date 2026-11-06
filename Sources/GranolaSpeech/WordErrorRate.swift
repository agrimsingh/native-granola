import Foundation

/// Word error rate over normalized text: lowercased, punctuation stripped, simple numbers and
/// common contractions spelled out, so engines aren't penalized for formatting choices.
public struct WordErrorRate: Sendable, Hashable, Codable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWords: Int

    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceWords: Int = 0) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWords = referenceWords
    }

    public var errors: Int { substitutions + deletions + insertions }
    public var rate: Double { referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }

    public static func + (a: Self, b: Self) -> Self {
        Self(substitutions: a.substitutions + b.substitutions, deletions: a.deletions + b.deletions,
             insertions: a.insertions + b.insertions, referenceWords: a.referenceWords + b.referenceWords)
    }

    public static func compute(reference: String, hypothesis: String) -> Self {
        align(normalize(reference), normalize(hypothesis))
    }

    /// Levenshtein alignment over words; ties prefer substitutions, then deletions.
    public static func align(_ ref: [String], _ hyp: [String]) -> Self {
        let n = ref.count, m = hyp.count
        if n == 0 { return Self(insertions: m) }
        if m == 0 { return Self(deletions: n, referenceWords: n) }
        struct Cell { var cost, s, d, i: Int }
        var prev = (0...m).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        var cur = prev
        for r in 1...n {
            cur[0] = Cell(cost: r, s: 0, d: r, i: 0)
            for h in 1...m {
                if ref[r - 1] == hyp[h - 1] {
                    cur[h] = prev[h - 1]
                    continue
                }
                let sub = prev[h - 1], del = prev[h], ins = cur[h - 1]
                let best = min(sub.cost, del.cost, ins.cost)
                if sub.cost == best { cur[h] = Cell(cost: best + 1, s: sub.s + 1, d: sub.d, i: sub.i) }
                else if del.cost == best { cur[h] = Cell(cost: best + 1, s: del.s, d: del.d + 1, i: del.i) }
                else { cur[h] = Cell(cost: best + 1, s: ins.s, d: ins.d, i: ins.i + 1) }
            }
            swap(&prev, &cur)
        }
        let c = prev[m]
        return Self(substitutions: c.s, deletions: c.d, insertions: c.i, referenceWords: n)
    }

    public static func normalize(_ text: String) -> [String] {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "%", with: " percent ")
            .replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[-–—/]"#, with: " ", options: .regularExpression)
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
        return words.flatMap(expand)
    }

    private static let contractions: [String: [String]] = [
        "i'm": ["i", "am"], "it's": ["it", "is"], "that's": ["that", "is"], "there's": ["there", "is"],
        "what's": ["what", "is"], "let's": ["let", "us"], "he's": ["he", "is"], "she's": ["she", "is"],
        "we're": ["we", "are"], "you're": ["you", "are"], "they're": ["they", "are"],
        "i've": ["i", "have"], "we've": ["we", "have"], "you've": ["you", "have"], "they've": ["they", "have"],
        "i'll": ["i", "will"], "we'll": ["we", "will"], "you'll": ["you", "will"], "they'll": ["they", "will"],
        "it'll": ["it", "will"], "i'd": ["i", "would"], "we'd": ["we", "would"], "you'd": ["you", "would"],
        "don't": ["do", "not"], "doesn't": ["does", "not"], "didn't": ["did", "not"], "can't": ["can", "not"],
        "won't": ["will", "not"], "isn't": ["is", "not"], "aren't": ["are", "not"], "wasn't": ["was", "not"],
        "weren't": ["were", "not"], "haven't": ["have", "not"], "hasn't": ["has", "not"],
        "couldn't": ["could", "not"], "wouldn't": ["would", "not"], "shouldn't": ["should", "not"],
        "cannot": ["can", "not"], "ok": ["okay"],
    ]

    private static func expand(_ word: String) -> [String] {
        if let c = contractions[word] { return c }
        if let ordinal = ordinalWords(word) { return ordinal }
        if word.allSatisfy(\.isNumber), let n = Int(word), n < 1_000_000 { return spell(n) }
        return [word]
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func spell(_ n: Int) -> [String] {
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        if n < 1000 { return [ones[n / 100], "hundred"] + (n % 100 == 0 ? [] : spell(n % 100)) }
        return spell(n / 1000) + ["thousand"] + (n % 1000 == 0 ? [] : spell(n % 1000))
    }

    private static let ordinalSuffix: [String: String] = [
        "one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth",
        "twelve": "twelfth",
    ]

    private static func ordinalWords(_ word: String) -> [String]? {
        guard word.count > 2, ["st", "nd", "rd", "th"].contains(String(word.suffix(2))),
              let n = Int(word.dropLast(2)), n < 1_000_000 else { return nil }
        var words = spell(n)
        let last = words.removeLast()
        if let o = ordinalSuffix[last] { return words + [o] }
        return words + [last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th"]
    }
}
