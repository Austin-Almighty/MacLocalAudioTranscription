import Foundation
import Testing
import Voz
import Who
@testable import LocalTranscription

private let conversation = [
    Word(text: "Hello", start: 0, end: 0.4),
    Word(text: "there", start: 0.5, end: 0.9),
    Word(text: "good", start: 1, end: 1.4),
    Word(text: "morning.", start: 1.5, end: 1.9),
]
private let turns = [Turn(start: 0, end: 1, speaker: 0), Turn(start: 1, end: 2, speaker: 1)]

struct SpeakerAttributionTests {
    @Test func splitsCuesAtSpeakerChangesWithoutLosingWordsOrTimings() {
        let speakers = SpeakerAttribution.speakers(for: conversation, turns: turns)
        #expect(speakers == [0, 0, 1, 1])
        let cues = Subtitles.cues(from: conversation, speakers: speakers)
        #expect(cues == [SubtitleCue(start: 0, end: 0.9, text: "Hello there", speaker: 0),
                         SubtitleCue(start: 1, end: 1.9, text: "good morning.", speaker: 1)])
    }

    @Test func usesTheLargestOverlapThenTheNearestTurnThenThePreviousWord() {
        let words = [Word(text: "far", start: 0, end: 0.4),
                     Word(text: "overlap", start: 5, end: 6),
                     Word(text: "near", start: 6.5, end: 6.8),
                     Word(text: "tie", start: 9, end: 10),
                     Word(text: "end", start: 12, end: 13)]
        let turns = [Turn(start: 5.5, end: 6, speaker: 1), Turn(start: 5, end: 6, speaker: 0),
                     Turn(start: 7, end: 8, speaker: 1),
                     Turn(start: 9, end: 10, speaker: 0), Turn(start: 9, end: 10, speaker: 1)]
        let speakers = SpeakerAttribution.speakers(for: words, turns: turns)
        // “far” is over a second from any turn with no word before it; “near” takes the closer turn
        // after it over the previous word’s speaker; “tie” and “end” keep the previous word’s speaker.
        #expect(speakers == [nil, 0, 1, 1, 1])
        #expect(Subtitles.cues(from: words, speakers: speakers).map(\.text) == ["far", "overlap", "near", "tie", "end"])
        #expect(SpeakerAttribution.speakers(for: words, turns: []) == [nil, nil, nil, nil, nil])
    }

    @Test func wordsInShortGapsAndTiesJoinANearbySpeakerInsteadOfAnUnlabelledParagraph() {
        // Scenario 7: Who leaves short silences between turns, where Voz often places “um” or a breath.
        let words = [Word(text: "Hi", start: 0, end: 0.5),
                     Word(text: "um", start: 1.2, end: 1.4),
                     Word(text: "yes", start: 2.1, end: 2.5),
                     Word(text: "so", start: 3.3, end: 3.5),
                     Word(text: "right.", start: 4.1, end: 4.5)]
        let turns = [Turn(start: 0, end: 1, speaker: 0), Turn(start: 2, end: 3, speaker: 1),
                     Turn(start: 4, end: 5, speaker: 0), Turn(start: 4, end: 5, speaker: 1)]
        let speakers = SpeakerAttribution.speakers(for: words, turns: turns)
        #expect(speakers == [0, 0, 1, 1, 1])
        let text = Subtitles.plainText("Hi um yes so right.", cues: Subtitles.cues(from: words, speakers: speakers))
        #expect(text.components(separatedBy: "\n\n").allSatisfy { $0.hasPrefix("Speaker ") })
        #expect(text == "Speaker 1: Hi um\n\nSpeaker 2: yes so right.")
    }

    @Test func zeroLengthAndOverlappedWordsTakeTheClosestTurnStillUnderway() {
        // An instant word inside a turn overlaps it by nothing, and a long earlier word can pull a later
        // turn into the sweep before a short word that ends before it starts.
        let instant = [Word(text: "yes", start: 0, end: 1), Word(text: "uh", start: 3, end: 3)]
        #expect(SpeakerAttribution.speakers(for: instant, turns: [Turn(start: 0, end: 1.5, speaker: 0),
                                                                  Turn(start: 2, end: 4, speaker: 1)]) == [0, 1])
        let overlapped = [Word(text: "long", start: 0, end: 5), Word(text: "short", start: 1, end: 2)]
        #expect(SpeakerAttribution.speakers(for: overlapped, turns: [Turn(start: 0, end: 0.5, speaker: 0),
                                                                     Turn(start: 2.2, end: 4, speaker: 1)]) == [1, 1])
    }

    @Test func discardsInvalidTurnsAndKeepsLongRecordingsInOrder() {
        let words = (0..<10_000).map { Word(text: "word", start: Double($0), end: Double($0) + 0.5) }
        let valid = (0..<10_000).map { Turn(start: Double($0), end: Double($0) + 0.8, speaker: $0 % 4) }
        let invalid = [Turn(start: .nan, end: 1, speaker: 0), Turn(start: 0, end: .infinity, speaker: 1),
                       Turn(start: 1, end: 0, speaker: 2), Turn(start: 0, end: 10_000, speaker: -1)]
        #expect(SpeakerAttribution.speakers(for: words, turns: invalid + valid) == (0..<10_000).map { Optional($0 % 4) })
    }

    @Test(arguments: 1...25 as ClosedRange<UInt64>)
    func shuffledAndOverlappingWordsKeepEveryWordTimingAndNearbyLabel(seed: UInt64) {
        // Scenario 11: Voz’s words may arrive out of order or overlap; the result must not depend on it.
        var random = SeededGenerator(seed: seed)
        var turns: [Turn] = []
        var time = 0.0
        for _ in 0..<Int.random(in: 3...12, using: &random) {
            time += Double.random(in: -0.5...1.5, using: &random)
            let length = Double.random(in: 0.2...3, using: &random)
            turns.append(Turn(start: max(0, time), end: max(0, time) + length, speaker: Int.random(in: 0...3, using: &random)))
            time += length
        }
        let sorted = (0..<Int.random(in: 1...60, using: &random)).map { index in
            let start = Double.random(in: 0...(time + 2), using: &random)
            return Word(text: "w\(index)", start: start, end: start + Double.random(in: 0...1.2, using: &random))
        }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let words = sorted.shuffled(using: &random)

        let speakers = SpeakerAttribution.speakers(for: words, turns: turns)
        #expect(speakers.count == words.count, "seed \(seed)")
        let bySortedOrder = SpeakerAttribution.speakers(for: sorted, turns: turns)
        let byText = Dictionary(uniqueKeysWithValues: zip(words.map(\.text), speakers))
        #expect(sorted.map { byText[$0.text] ?? nil } == bySortedOrder, "seed \(seed): order changed the labels")

        // A brute-force reference over every turn: the clear overlap, else the single closest voice within
        // the window, else the previous word’s label.
        var previous: Int?
        let expected = sorted.map { word -> Int? in
            var overlaps: [Int: Double] = [:]
            for turn in turns {
                let overlap = min(word.end, turn.end) - max(word.start, turn.start)
                if overlap > 0 { overlaps[turn.speaker, default: 0] += overlap }
            }
            let longest = overlaps.values.max() ?? 0
            let winners = Set(overlaps.filter { abs($0.value - longest) < 0.000_001 }.keys)
            let distances = turns.map { (distance: max(0, $0.start - word.end, word.start - $0.end), speaker: $0.speaker) }
                .filter { $0.distance <= SpeakerAttribution.window }
            let closest = distances.map(\.distance).min() ?? 0
            let nearest = Set(distances.filter { $0.distance - closest < 0.000_001 }.map(\.speaker))
            let label = winners.count == 1 ? winners.first : overlaps.isEmpty && nearest.count == 1 ? nearest.first : previous
            previous = label
            return label
        }
        #expect(bySortedOrder == expected, "seed \(seed)")

        // Every word reaches the cues in its original order, and each cue starts at its first word.
        let cues = Subtitles.cues(from: words, speakers: speakers)
        #expect(cues.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) } == words.map(\.text),
                "seed \(seed)")
        var next = 0
        for cue in cues {
            #expect(cue.start == words[next].start, "seed \(seed)")
            next += cue.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    @Test func exportsSpeakerLabelsWithoutChangingTheEditableText() {
        let cues = Subtitles.cues(from: conversation, speakers: [0, 0, 1, 1])
        #expect(TranscriptFormat.text.render(transcript: "Hello there good morning.", cues: cues)
                == "Speaker 1: Hello there\n\nSpeaker 2: good morning.")
        #expect(Subtitles.subRip(cues) == "1\n00:00:00,000 --> 00:00:00,900\nSpeaker 1: Hello there\n\n2\n00:00:01,000 --> 00:00:01,900\nSpeaker 2: good morning.\n")
        #expect(Subtitles.webVTT(cues) == "WEBVTT\n\n00:00:00.000 --> 00:00:00.900\nSpeaker 1: Hello there\n\n00:00:01.000 --> 00:00:01.900\nSpeaker 2: good morning.\n")
        let long = (0..<40).map { Word(text: "speaking", start: Double($0) * 0.1, end: Double($0) * 0.1 + 0.1) }
        for cue in Subtitles.cues(from: long, speakers: Array(repeating: 0, count: long.count)) {
            let lines = cue.labelledText.split(separator: "\n")
            #expect(lines.count <= 2)
            #expect(lines.allSatisfy { $0.count <= Subtitles.maxLineLength })
        }
    }

    @Test func groupsContiguousSpeakersAndLeavesUnattributedWordsVisible() {
        let cues = [SubtitleCue(start: 0, end: 1, text: "First sentence.", speaker: 0),
                    SubtitleCue(start: 1, end: 2, text: "Second\nsentence.", speaker: 0),
                    SubtitleCue(start: 2, end: 3, text: "Uncertain."),
                    SubtitleCue(start: 3, end: 4, text: "Another voice.", speaker: 1)]
        #expect(Subtitles.plainText("", cues: cues)
                == "Speaker 1: First sentence. Second sentence.\n\nUncertain.\n\nSpeaker 2: Another voice.")
    }

    @Test func loadsHistoryWrittenBeforeSpeakerLabelsExisted() throws {
        let json = Data(#"{"transcript":"Hello.","cues":[{"start":0,"end":1,"text":"Hello."}]}"#.utf8)
        let old = try JSONDecoder().decode(TranscriptRecord.self, from: json)
        #expect(old.cues.first?.speaker == nil)
        #expect(Subtitles.plainText(old.transcript, cues: old.cues) == "Hello.")
        #expect(try JSONDecoder().decode(TranscriptRecord.self, from: JSONEncoder().encode(old)) == old)
    }
}

/// SplitMix64, so each randomised case is the same on every run and a failing seed can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private actor FakeSpeakerIdentifier: SpeakerIdentifying {
    private(set) var calls = 0
    let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    func identify(_ url: URL) throws -> [Turn] {
        calls += 1
        if fails { throw CocoaError(.fileReadCorruptFile) }
        return turns
    }
}

@MainActor
struct SpeakerIdentificationTests {
    @Test func disabledIdentificationAndSilenceNeverLoadWho() async {
        let identifier = FakeSpeakerIdentifier()
        let model = TranscriptionModel(speakers: identifier, history: .temporary())
        #expect(!model.identifySpeakers)
        let url = URL(fileURLWithPath: "/unused.wav")
        let cues = await model.subtitleCues(from: conversation, url: url, identifySpeakers: false)
        #expect(cues == Subtitles.cues(from: conversation))
        #expect(await model.subtitleCues(from: [], url: url, identifySpeakers: true).isEmpty)
        #expect(await identifier.calls == 0)
        #expect(!model.isBusy)
    }

    @Test func failedIdentificationPreservesTheTranscriptAndReportsTheFile() async {
        let identifier = FakeSpeakerIdentifier(fails: true)
        let model = TranscriptionModel(speakers: identifier, history: .temporary())
        let cues = await model.subtitleCues(from: conversation, url: URL(fileURLWithPath: "/interview.wav"), identifySpeakers: true)
        #expect(cues == Subtitles.cues(from: conversation))
        #expect(await identifier.calls == 1)
        #expect(model.errorMessage?.contains("“interview.wav” was transcribed") == true)
        #expect(!model.isBusy)
    }

    @Test func labelsSurviveHistoryReopeningEditingAndReverting() async throws {
        let history = TranscriptHistory.temporary()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        let model = TranscriptionModel(speakers: FakeSpeakerIdentifier(), history: history)
        let cues = await model.subtitleCues(from: conversation, url: URL(fileURLWithPath: "/interview.wav"), identifySpeakers: true)
        let entry = HistoryEntry(id: UUID(), fileName: "interview.wav", date: .now, audioDuration: 2,
                                 processingTime: 0.1, language: nil)
        let record = TranscriptRecord(transcript: "Hello there good morning.", cues: cues)
        model.finishTranscription(entry, record: record)
        #expect(model.speakerCount == 2)
        #expect(model.transcript == record.transcript)
        #expect(model.displayTranscript == "Speaker 1: Hello there\n\nSpeaker 2: good morning.")

        let reopened = TranscriptHistory(directory: history.directory)
        await reopened.load()
        let editor = TranscriptionModel(history: reopened)
        await editor.select(entry.id)
        #expect(editor.cues == cues)
        editor.beginEditing()
        #expect(editor.draft == record.transcript)
        editor.updateDraft("Hello there good evening.")
        #expect(editor.endEditing())
        #expect(editor.cues.map(\.speaker) == [0, 1])
        #expect(editor.cues.map(\.start) == cues.map(\.start))
        #expect(editor.displayTranscript == "Speaker 1: Hello there\n\nSpeaker 2: good evening.")

        editor.beginEditing()
        editor.updateDraft("")
        #expect(editor.saveDraft())
        editor.updateDraft(record.transcript)
        #expect(editor.endEditing())
        #expect(editor.cues == cues)
        await editor.revertToOriginal()
        #expect(try await reopened.record(for: entry.id) == record)
    }

    @Test func theQueueAndLanguageWarningsKeepTheSettingAtImportTime() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let chinese = DetectedLanguage(code: "zh", confidence: 0.99, isReliable: true)
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(result: chinese), history: .temporary())
        model.identifySpeakers = true
        await model.importFiles([file, file])
        #expect(try #require(model.languageWarning).identifySpeakers)
        model.identifySpeakers = false
        await model.dismissLanguageWarning()
        #expect(try #require(model.languageWarning).identifySpeakers)
        await model.importFiles([file])
        await model.dismissLanguageWarning()
        #expect(!(try #require(model.languageWarning).identifySpeakers))
        model.clearQueue()
        await model.dismissLanguageWarning()
    }
}
