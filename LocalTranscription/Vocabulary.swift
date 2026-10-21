import Foundation

/// Names and terms a recording likely contains, which Voz prefers when it was close to them anyway.
/// Voz notes that a long, general list makes transcripts worse, so the list applies only to the
/// recordings imported while it is set.
enum Vocabulary {
    /// Beyond this many terms, the app suggests trimming the list.
    static let suggestedLimit = 30

    /// Splits text on commas and line breaks into terms, keeping their case and order and
    /// dropping blanks and exact repeats. Spaces inside a term are kept, so phrases work.
    static func terms(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
