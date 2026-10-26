import Foundation
import UniformTypeIdentifiers
import Voz

struct SubtitleCue: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Who’s zero-based speaker number, absent in older or unlabelled transcripts.
    var speaker: Int? = nil

    var speakerLabel: String? { speaker.map { "Speaker \($0 + 1)" } }
    var labelledText: String {
        guard let speakerLabel else { return text }
        return Subtitles.layout("\(speakerLabel): " + text.replacingOccurrences(of: "\n", with: " "))
    }
}

/// Groups Voz’s word timings into readable subtitle cues and writes them as SRT or WebVTT.
enum Subtitles {
    static let maxCueDuration: TimeInterval = 6
    static let maxLineLength = 42
    static let minCueDuration: TimeInterval = 0.5
    static let maxPause: TimeInterval = 1

    static func cues(from words: [Word], speakers: [Int?] = []) -> [SubtitleCue] {
        var groups: [(words: [Word], speaker: Int?)] = []
        var current: [Word] = []
        var currentSpeaker: Int?
        for (index, word) in words.enumerated() {
            let speaker = index < speakers.count ? speakers[index] : nil
            if let first = current.first, let last = current.last {
                let text = (current + [word]).map(\.text).joined(separator: " ")
                let labelled = speaker.map { "Speaker \($0 + 1): " } ?? ""
                if word.start - last.end > maxPause || word.end - first.start > maxCueDuration
                    || currentSpeaker != speaker || wrapped(labelled + text) == nil {
                    groups.append((current, currentSpeaker))
                    current = []
                }
            }
            currentSpeaker = speaker
            current.append(word)
            if endsSentence(word.text) {
                groups.append((current, currentSpeaker))
                current = []
            }
        }
        if !current.isEmpty { groups.append((current, currentSpeaker)) }

        return groups.indices.map { index in
            let group = groups[index].words
            let start = group[0].start
            var end = max(group[group.count - 1].end, start + minCueDuration)
            // Keep cues from overlapping the next one after the minimum duration is applied.
            if index + 1 < groups.count { end = max(start, min(end, groups[index + 1].words[0].start)) }
            let text = group.map(\.text).joined(separator: " ")
            return SubtitleCue(start: start, end: end, text: wrapped(text) ?? text, speaker: groups[index].speaker)
        }
    }

    static func subRip(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.labelledText)\n"
        }.joined(separator: "\n")
    }

    static func webVTT(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n" + cues.map { cue in
            "\n\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.labelledText)\n"
        }.joined()
    }

    /// Speaker headings are presentation only; the editable transcript keeps just the spoken words.
    static func plainText(_ transcript: String, cues: [SubtitleCue]) -> String {
        guard cues.contains(where: { $0.speaker != nil }) else { return transcript }
        var groups: [(speaker: Int?, text: [String])] = []
        for cue in cues {
            let text = cue.text.replacingOccurrences(of: "\n", with: " ")
            if !groups.isEmpty, groups[groups.count - 1].speaker == cue.speaker {
                groups[groups.count - 1].text.append(text)
            } else {
                groups.append((cue.speaker, [text]))
            }
        }
        return groups.map { group in
            let label = group.speaker.map { "Speaker \($0 + 1): " } ?? ""
            return label + group.text.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    /// Formats seconds as `HH:MM:SS` followed by the separator and milliseconds.
    static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let total = max(0, Int((seconds * 1000).rounded()))
        let (hours, minutes, secs, millis) = (total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }

    /// Lays out cue text on at most two lines when it fits, otherwise on one, never dropping words.
    static func layout(_ text: String) -> String {
        wrapped(text) ?? text
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…".contains(last)
    }

    /// Returns the text on at most two lines within the line limit, or nil if it doesn’t fit.
    /// A single word longer than a line is kept as is.
    private static func wrapped(_ text: String) -> String? {
        guard text.count > maxLineLength else { return text }
        let spaces = text.indices.filter { text[$0] == " " }
        guard !spaces.isEmpty else { return text }
        guard let best = spaces.min(by: { longestLine(text, splitAt: $0) < longestLine(text, splitAt: $1) }),
              longestLine(text, splitAt: best) <= maxLineLength else { return nil }
        return String(text[..<best]) + "\n" + String(text[text.index(after: best)...])
    }

    private static func longestLine(_ text: String, splitAt space: String.Index) -> Int {
        let first = text.distance(from: text.startIndex, to: space)
        return max(first, text.count - first - 1)
    }
}

enum TranscriptFormat: CaseIterable, Sendable {
    case text, subRip, webVTT

    var fileExtension: String {
        switch self {
        case .text: "txt"
        case .subRip: "srt"
        case .webVTT: "vtt"
        }
    }

    // Not every Mac declares SRT, so subtitle types are resolved from their extensions.
    var contentType: UTType {
        switch self {
        case .text: .plainText
        case .subRip: UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
        case .webVTT: UTType(filenameExtension: "vtt", conformingTo: .text) ?? .plainText
        }
    }

    func render(transcript: String, cues: [SubtitleCue]) -> String {
        switch self {
        case .text: Subtitles.plainText(transcript, cues: cues)
        case .subRip: Subtitles.subRip(cues)
        case .webVTT: Subtitles.webVTT(cues)
        }
    }
}
