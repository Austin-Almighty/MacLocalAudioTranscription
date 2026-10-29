import Foundation
import Testing
@testable import LocalTranscription

private let cues = [
    SubtitleCue(start: 0, end: 2, text: "This is a local"),
    SubtitleCue(start: 2.2, end: 4, text: "speech recognition test."),
    SubtitleCue(start: 4.5, end: 7, text: "The quick brown fox."),
]
private let transcript = "This is a local speech recognition test. The quick brown fox."

struct CueAlignmentTests {
    private func texts(_ edited: String) -> [String] {
        CueAlignment.realign(cues, to: edited).map(\.text)
    }

    @Test func keepsUnchangedTextAndTimingsExactly() {
        #expect(CueAlignment.realign(cues, to: transcript) == cues)
    }

    @Test func fixesATypoWithinItsCue() {
        let edited = CueAlignment.realign(cues, to: "This is a local speech recognition test. The quick brown box.")
        #expect(edited.map(\.text) == ["This is a local", "speech recognition test.", "The quick brown box."])
        #expect(edited.map(\.start) == cues.map(\.start))
        #expect(edited.map(\.end) == cues.map(\.end))
    }

    @Test func replacingACuesFirstWordKeepsItInThatCue() {
        #expect(texts("This is a local voice recognition test. The quick brown fox.")
                == ["This is a local", "voice recognition test.", "The quick brown fox."])
    }

    @Test func insertionsJoinThePrecedingWordsCue() {
        #expect(texts("This is a local offline speech recognition test. The quick brown fox.")
                == ["This is a local offline", "speech recognition test.", "The quick brown fox."])
    }

    @Test func insertionsAtTheStartJoinTheFirstCue() {
        #expect(texts("Hello. This is a local speech recognition test. The quick brown fox.")
                == ["Hello. This is a local", "speech recognition test.", "The quick brown fox."])
    }

    @Test func deletingACuesWordsRemovesTheCue() {
        let edited = CueAlignment.realign(cues, to: "This is a local The quick brown fox.")
        #expect(edited.map(\.text) == ["This is a local", "The quick brown fox."])
        #expect(edited.map(\.start) == [0, 4.5])
    }

    @Test func spreadsAPastedReplacementAcrossTheCues() {
        let edited = CueAlignment.realign(cues, to: "one two three four five six seven eight nine ten eleven twelve")
        #expect(edited.count == 3)
        #expect(edited.map(\.start) == cues.map(\.start))
        #expect(edited.map(\.text).joined(separator: " ") == "one two three four five six seven eight nine ten eleven twelve")
    }

    @Test func emptyTextHasNoCues() {
        #expect(CueAlignment.realign(cues, to: "  \n ").isEmpty)
        #expect(CueAlignment.realign([], to: transcript).isEmpty)
    }

    @Test func ignoresLineBreaksAndKeepsUnicode() {
        #expect(texts("This is a local\n\nspeech recognition test. The quick café 🎙️ fox.")
                == ["This is a local", "speech recognition test.", "The quick café 🎙️ fox."])
    }

    @Test func wrapsAGrowingCueOntoTwoLines() {
        let edited = CueAlignment.realign(cues, to: "This is a local speech recognition test. The quick brown fox jumps over the lazy dog.")
        #expect(edited.last?.text == "The quick brown fox\njumps over the lazy dog.")
    }

    @Test func keepsEveryWordWhenACueOutgrowsTwoLines() {
        let long = "This is a local speech recognition test. The quick brown fox jumps over the lazy dog while the band plays on and on and on into the night."
        let edited = CueAlignment.realign(cues, to: long)
        #expect(edited.map(\.text).joined(separator: " ").replacingOccurrences(of: "\n", with: " ") == long)
        #expect(edited.map(\.start) == cues.map(\.start))
    }
}

/// Scenario 8: editing across a speaker change keeps this behavior, as decided in FAILURE_SCENARIOS.md.
struct SpeakerEditingTests {
    private let labelled = [SubtitleCue(start: 0, end: 0.9, text: "Hello there", speaker: 0),
                            SubtitleCue(start: 1, end: 1.9, text: "good morning.", speaker: 1)]

    private func realign(_ text: String) -> [String] {
        CueAlignment.realign(labelled, to: text).map { "\($0.speaker.map(String.init) ?? "-"): \($0.text)" }
    }

    @Test func deletingOneSpeakersWordsDropsTheirCue() {
        #expect(realign("Hello there") == ["0: Hello there"])
        #expect(realign("good morning.") == ["1: good morning."])
    }

    @Test func aReplacementAcrossTheChangeKeepsEachReplacedWordsSpeaker() {
        // “friend,” replaces speaker 1’s “there” and “nice” replaces speaker 2’s “good”, word for word.
        #expect(realign("Hello friend, nice morning.") == ["0: Hello friend,", "1: nice morning."])
    }

    @Test func wordsTypedAtTheChangeGoToTheSpeakerBefore() {
        #expect(realign("Hello there. Yes, good morning.") == ["0: Hello there. Yes,", "1: good morning."])
    }

    @Test func pastingOverEverythingSpreadsWordsByPosition() {
        #expect(realign("one two three four five six") == ["0: one two three", "1: four five six"])
    }
}

@MainActor
final class TranscriptEditingTests {
    let history = TranscriptHistory.temporary()
    let directory: URL
    private let entry = HistoryEntry(id: UUID(), fileName: "speech.wav", date: Date(timeIntervalSince1970: 1_000),
                                     audioDuration: 7, processingTime: 0.1, language: nil)
    private let record = TranscriptRecord(transcript: transcript, cues: cues)

    init() { directory = history.directory }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func editedModel() async throws -> TranscriptionModel {
        try history.save(entry, record)
        let model = TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(), history: history)
        await model.select(entry.id)
        return model
    }

    @Test func editsPersistAndKeepTheOriginalOnce() async throws {
        try history.save(entry, record)
        let first = TranscriptRecord(transcript: "First edit.", cues: [SubtitleCue(start: 0, end: 2, text: "First edit.")])
        let second = TranscriptRecord(transcript: "Second edit.", cues: [SubtitleCue(start: 0, end: 2, text: "Second edit.")])
        try history.update(entry.id, first, editedAt: Date(timeIntervalSince1970: 2_000))
        try history.update(entry.id, second, editedAt: Date(timeIntervalSince1970: 3_000))

        let reopened = TranscriptHistory(directory: directory)
        await reopened.load()
        #expect(reopened.entries.map(\.id) == [entry.id])
        #expect(reopened.entries.first?.edited == Date(timeIntervalSince1970: 3_000))
        #expect(try await reopened.record(for: entry.id) == second)

        #expect(try await reopened.revert(entry.id) == record)
        #expect(reopened.entries.first?.edited == nil)
        #expect(try files() == ["\(entry.id.uuidString).json", "\(entry.id.uuidString).transcript.json"])
    }

    @Test func deletingAnEditedEntryRemovesItsOriginalToo() throws {
        try history.save(entry, record)
        try history.update(entry.id, TranscriptRecord(transcript: "Edited.", cues: []), editedAt: .now)
        #expect(try files().count == 3)
        try history.delete(entry.id)
        #expect(try files().isEmpty)
    }

    @Test func doneSavesTheEditWithRealignedSubtitles() async throws {
        let model = try await editedModel()
        model.beginEditing()
        #expect(model.draft == transcript)
        model.updateDraft("This is a local speech recognition test.\n\nThe quick brown box.")
        model.endEditing()

        #expect(!model.isEditing)
        #expect(model.transcript == "This is a local speech recognition test.\n\nThe quick brown box.")
        #expect(model.cues.map(\.text) == ["This is a local", "speech recognition test.", "The quick brown box."])
        #expect(model.editedDate != nil)
        let saved = try await history.record(for: entry.id)
        #expect(saved == TranscriptRecord(transcript: model.transcript, cues: model.cues))
        // Exports use the edited text.
        #expect(TranscriptFormat.subRip.render(transcript: model.transcript, cues: model.cues).contains("brown box."))
    }

    @Test func switchingEntriesSavesTheDraftToItsOwnEntry() async throws {
        let other = HistoryEntry(id: UUID(), fileName: "other.wav", date: Date(timeIntervalSince1970: 500),
                                 audioDuration: 2, processingTime: 0.1, language: nil)
        try history.save(other, TranscriptRecord(transcript: "Other.", cues: []))
        let model = try await editedModel()
        model.beginEditing()
        model.updateDraft("This is a local speech test. The quick brown fox.")
        await model.select(other.id)

        #expect(!model.isEditing)
        #expect(model.transcript == "Other.")
        #expect(try await history.record(for: entry.id).transcript == "This is a local speech test. The quick brown fox.")
        #expect(try await history.record(for: other.id).transcript == "Other.")
    }

    @Test func restoringDeletedTextAfterSavingRestoresItsCueTimings() async throws {
        let model = try await editedModel()
        model.beginEditing()
        for deleted in ["", "This is a local The quick brown fox."] {
            model.updateDraft(deleted)
            model.saveDraft()
            #expect(model.cues.count < cues.count)

            model.updateDraft(transcript)
            model.saveDraft()
            #expect(model.cues == cues)
            #expect(try await history.record(for: entry.id) == record)
        }
        model.endEditing()
    }

    @Test func restoringAnEmptySavedTranscriptAfterReopeningRestoresItsCueTimings() async throws {
        let model = try await editedModel()
        model.beginEditing()
        model.updateDraft("")
        model.endEditing()

        let reopened = TranscriptHistory(directory: directory)
        await reopened.load()
        let editor = TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(), history: reopened)
        await editor.select(entry.id)
        #expect(editor.transcript.isEmpty)
        #expect(editor.cues.isEmpty)
        editor.beginEditing()
        editor.updateDraft(transcript)
        editor.endEditing()

        #expect(editor.cues == cues)
        #expect(try await reopened.record(for: entry.id) == record)
    }

    @Test func anUnreadableOriginalIsNotReplacedByTheEditedRecord() throws {
        try history.save(entry, record)
        #expect(try history.originalRecord(for: entry.id) == record)
        try history.update(entry.id, TranscriptRecord(transcript: "Edited.", cues: []), editedAt: .now)
        try Data("not JSON".utf8).write(to: directory.appending(path: "\(entry.id.uuidString).original.transcript.json"))

        #expect(throws: (any Error).self) { try self.history.originalRecord(for: self.entry.id) }
    }

    @Test func autosavesShortlyAfterTypingStops() async throws {
        let model = try await editedModel()
        model.beginEditing()
        model.updateDraft("Autosaved text.")
        #expect(try await history.record(for: entry.id).transcript == transcript)
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.isEditing)
        #expect(try await history.record(for: entry.id).transcript == "Autosaved text.")
    }

    @Test func deletingTheEditedEntryDropsTheDraft() async throws {
        let model = try await editedModel()
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        model.deleteEntry(entry.id)
        #expect(!model.isEditing)
        #expect(model.selection == nil)
        #expect(model.transcript.isEmpty)
        #expect(try files().isEmpty)
    }

    @Test func revertRestoresTheTranscriptAsTranscribed() async throws {
        let model = try await editedModel()
        model.beginEditing()
        model.updateDraft("Edited away.")
        await model.revertToOriginal()
        #expect(!model.isEditing)
        #expect(model.transcript == transcript)
        #expect(model.cues == cues)
        #expect(model.editedDate == nil)
    }

    @Test func anotherWindowShowsTheEditedVersion() async throws {
        let editor = try await editedModel()
        let viewer = TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(), history: history)
        await viewer.select(entry.id)

        editor.beginEditing()
        editor.updateDraft("Edited in another window.")
        editor.endEditing()
        viewer.reconcileWithHistory()
        for _ in 0..<50 where viewer.transcript != "Edited in another window." {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewer.transcript == "Edited in another window.")
        #expect(viewer.editedDate == editor.editedDate)
    }

    @Test func unsavedTranscriptsCannotBeEdited() {
        let model = TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(), history: history)
        #expect(!model.canEdit)
        model.beginEditing()
        #expect(!model.isEditing)
    }
}
