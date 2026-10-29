import Foundation
import Voz
import Who

protocol SpeakerIdentifying: Sendable {
    func identify(_ url: URL) async throws -> [Turn]
}

/// Reuses Who across windows; construction does not download or load its model.
struct WhoSpeakerIdentifier: SpeakerIdentifying {
    static let shared = WhoSpeakerIdentifier()
    private let who = Who()

    func identify(_ url: URL) async throws -> [Turn] {
        try await who.diarize(contentsOf: url).turns
    }
}

enum SpeakerAttribution {
    /// How far a word may sit from a turn and still take its speaker. A pause of up to this long
    /// doesn’t split a subtitle cue either, so such a word still belongs to the same stretch of speech.
    static let window = Subtitles.maxPause

    /// Assigns each word to the voice with the most overlapping speech. A word in a gap takes the
    /// nearest turn within `window`; a tie, or a gap with no single nearest voice, keeps the previous
    /// word’s speaker. Words are matched in time order, whatever order Voz returns them in.
    static func speakers(for words: [Word], turns: [Turn]) -> [Int?] {
        let turns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.speaker >= 0 }
            .sorted { $0.start < $1.start }
        let order = words.indices.filter { words[$0].start.isFinite && words[$0].end.isFinite }
            .sorted { (words[$0].start, words[$0].end, $0) < (words[$1].start, words[$1].end, $1) }
        var result = [Int?](repeating: nil, count: words.count)
        var next = 0
        var active: [Turn] = [], ended: [Turn] = []
        var previous: Int?
        for index in order {
            let word = words[index]
            while next < turns.count, turns[next].start < word.end {
                active.append(turns[next])
                next += 1
            }
            ended += active.filter { $0.end <= word.start }
            active.removeAll { $0.end <= word.start }
            ended.removeAll { word.start - $0.end > window }

            let speaker = overlapping(word, active)
                ?? nearest(word, candidates: ended + active, upcoming: turns[next...]) ?? previous
            result[index] = speaker
            previous = speaker
        }
        return result
    }

    /// The single speaker with the most speech during the word, or nil for a gap or a tie.
    private static func overlapping(_ word: Word, _ turns: [Turn]) -> Int? {
        var overlaps: [Int: Double] = [:]
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > 0 { overlaps[turn.speaker, default: 0] += overlap }
        }
        guard let longest = overlaps.values.max() else { return nil }
        let winners = overlaps.filter { abs($0.value - longest) < 0.000_001 }
        return winners.count == 1 ? winners.first?.key : nil
    }

    /// The speaker of the closest turn within `window`, or nil when none is that close or two voices are equally close.
    /// Turns already underway count too: an instant word inside one overlaps it by nothing.
    private static func nearest(_ word: Word, candidates: [Turn], upcoming: ArraySlice<Turn>) -> Int? {
        var nearby = candidates.map { (distance: max(0, $0.start - word.end, word.start - $0.end), speaker: $0.speaker) }
            .filter { $0.distance <= window }
        for turn in upcoming {
            guard turn.start - word.end <= window else { break }
            nearby.append((turn.start - word.end, turn.speaker))
        }
        guard let closest = nearby.map(\.distance).min() else { return nil }
        let speakers = Set(nearby.filter { $0.distance - closest < 0.000_001 }.map(\.speaker))
        return speakers.count == 1 ? speakers.first : nil
    }
}
