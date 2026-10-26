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

    @Test func usesTheLargestOverlapLeavingGapsAndTiesUnlabelled() {
        let words = [Word(text: "gap", start: 0, end: 0.4),
                     Word(text: "overlap", start: 1, end: 2),
                     Word(text: "tie", start: 3, end: 4),
                     Word(text: "end", start: 6, end: 7)]
        let turns = [Turn(start: 1.5, end: 2, speaker: 1), Turn(start: 1, end: 2, speaker: 0),
                     Turn(start: 3, end: 4, speaker: 0), Turn(start: 3, end: 4, speaker: 1)]
        let speakers = SpeakerAttribution.speakers(for: words, turns: turns)
        #expect(speakers == [nil, 0, nil, nil])
        #expect(Subtitles.cues(from: words, speakers: speakers).map(\.text) == ["gap", "overlap", "tie", "end"])
        #expect(SpeakerAttribution.speakers(for: words, turns: []) == [nil, nil, nil, nil])
    }

    @Test func discardsInvalidTurnsAndKeepsLongRecordingsInOrder() {
        let words = (0..<10_000).map { Word(text: "word", start: Double($0), end: Double($0) + 0.5) }
        let valid = (0..<10_000).map { Turn(start: Double($0), end: Double($0) + 0.8, speaker: $0 % 4) }
        let invalid = [Turn(start: .nan, end: 1, speaker: 0), Turn(start: 0, end: .infinity, speaker: 1),
                       Turn(start: 1, end: 0, speaker: 2), Turn(start: 0, end: 10_000, speaker: -1)]
        #expect(SpeakerAttribution.speakers(for: words, turns: invalid + valid) == (0..<10_000).map { Optional($0 % 4) })
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
