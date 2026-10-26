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
    /// Assigns each word to the voice with the most overlapping speech. Gaps and ties stay unlabelled.
    static func speakers(for words: [Word], turns: [Turn]) -> [Int?] {
        let turns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.speaker >= 0 }
            .sorted { $0.start < $1.start }
        var next = 0
        var active: [Turn] = []
        return words.map { word in
            while next < turns.count, turns[next].start < word.end {
                active.append(turns[next])
                next += 1
            }
            active.removeAll { $0.end <= word.start }
            var overlaps: [Int: Double] = [:]
            for turn in active {
                let overlap = min(word.end, turn.end) - max(word.start, turn.start)
                if overlap > 0 { overlaps[turn.speaker, default: 0] += overlap }
            }
            guard let longest = overlaps.values.max() else { return nil }
            let winners = overlaps.filter { abs($0.value - longest) < 0.000_001 }
            return winners.count == 1 ? winners.first?.key : nil
        }
    }
}
