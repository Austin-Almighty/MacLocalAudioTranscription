import Foundation

/// Keeps subtitle cues in step with an edited transcript. Each word of the edit goes into the cue of
/// the words it replaces or follows, so every cue keeps its original timing.
enum CueAlignment {
    /// Above this many changed words on either side, words are spread by position instead of
    /// diffed, which keeps a large rewrite fast and its memory small.
    static let diffLimit = 1_000

    static func realign(_ cues: [SubtitleCue], to text: String) -> [SubtitleCue] {
        let newWords = words(text)
        var oldWords: [String] = [], oldCues: [Int] = []
        for (index, cue) in cues.enumerated() {
            for word in words(cue.text) {
                oldWords.append(word)
                oldCues.append(index)
            }
        }
        guard !newWords.isEmpty, !oldWords.isEmpty else { return [] }

        // Words shared at both ends keep their cues without diffing.
        let shortest = min(oldWords.count, newWords.count)
        var prefix = 0
        while prefix < shortest, oldWords[prefix] == newWords[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              oldWords[oldWords.count - 1 - suffix] == newWords[newWords.count - 1 - suffix] { suffix += 1 }

        let oldMiddle = prefix..<(oldWords.count - suffix)
        let newMiddle = prefix..<(newWords.count - suffix)
        let middle = alignMiddle(old: Array(oldWords[oldMiddle]), oldCues: Array(oldCues[oldMiddle]),
                                 new: Array(newWords[newMiddle]),
                                 before: prefix > 0 ? oldCues[prefix - 1] : nil,
                                 after: suffix > 0 ? oldCues[oldWords.count - suffix] : nil)
        let assignment = Array(oldCues[..<prefix]) + middle + Array(oldCues[(oldWords.count - suffix)...])

        var grouped = [[String]](repeating: [], count: cues.count)
        for (word, cue) in zip(newWords, assignment) { grouped[cue].append(word) }
        return zip(cues, grouped).compactMap { cue, words in
            words.isEmpty ? nil : SubtitleCue(start: cue.start, end: cue.end,
                                              text: Subtitles.layout(words.joined(separator: " ")))
        }
    }

    /// Assigns the changed words between the shared ends to cues.
    private static func alignMiddle(old: [String], oldCues: [Int], new: [String],
                                    before: Int?, after: Int?) -> [Int] {
        guard !new.isEmpty else { return [] }
        // A pure insertion joins the preceding word’s cue, or the following one at the very start.
        guard let lastCue = oldCues.last else {
            return Array(repeating: before ?? after ?? 0, count: new.count)
        }
        guard old.count <= diffLimit, new.count <= diffLimit else { return spread(new.count, over: oldCues) }
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Nothing kept, as after pasting over everything: spread the words instead of piling them up.
        guard removed.count < old.count else { return spread(new.count, over: oldCues) }

        var result: [Int] = []
        result.reserveCapacity(new.count)
        var oldIndex = 0, newIndex = 0
        var replacedCue: Int?, previousCue = before
        while newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                // Words replacing a removed run go where the run began.
                replacedCue = replacedCue ?? oldCues[oldIndex]
                oldIndex += 1
            } else if inserted.contains(newIndex) {
                let next = oldIndex < old.count ? oldCues[oldIndex] : (after ?? lastCue)
                result.append(replacedCue ?? previousCue ?? next)
                newIndex += 1
            } else {
                previousCue = oldCues[oldIndex]
                replacedCue = nil
                result.append(oldCues[oldIndex])
                oldIndex += 1
                newIndex += 1
            }
        }
        return result
    }

    /// Spreads words across cues in proportion to how many words each cue had.
    private static func spread(_ count: Int, over oldCues: [Int]) -> [Int] {
        (0..<count).map { oldCues[$0 * oldCues.count / count] }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
