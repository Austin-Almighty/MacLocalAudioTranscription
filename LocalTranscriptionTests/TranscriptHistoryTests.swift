import Foundation
import Testing
@testable import LocalTranscription

extension TranscriptHistory {
    /// A history in its own temporary folder, so tests never touch the person’s saved transcripts.
    /// The folder is created only when something is saved.
    static func temporary() -> TranscriptHistory {
        TranscriptHistory(directory: FileManager.default.temporaryDirectory
            .appending(path: "LocalTranscriptionTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }
}

private func entry(_ name: String, at seconds: TimeInterval, language: DetectedLanguage? = nil) -> HistoryEntry {
    HistoryEntry(id: UUID(), fileName: name, date: Date(timeIntervalSince1970: seconds),
                 audioDuration: 5.79, processingTime: 0.1, language: language)
}

private let english = DetectedLanguage(code: "en", confidence: 0.99, isReliable: true)
private let unicodeRecord = TranscriptRecord(transcript: "Café — 訪談 🎙️",
                                             cues: [SubtitleCue(start: 0, end: 1.5, text: "Café —\n訪談 🎙️")])
private let emptyRecord = TranscriptRecord(transcript: "", cues: [])

@MainActor
final class TranscriptHistoryTests {
    let history = TranscriptHistory.temporary()
    let directory: URL

    init() { directory = history.directory }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func jsonFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
    }

    @Test func savedTranscriptsReloadInANewSession() async throws {
        let interview = entry("訪談 café 🎙️.m4a", at: 1_000, language: english)
        let silence = entry("blank.wav", at: 2_000)
        try history.save(interview, unicodeRecord)
        try history.save(silence, emptyRecord)

        let reopened = TranscriptHistory(directory: directory)
        await reopened.load()
        #expect(reopened.entries == [silence, interview])
        #expect(try await reopened.record(for: interview.id) == unicodeRecord)
        #expect(try await reopened.record(for: silence.id) == emptyRecord)
    }

    @Test func listsNewestFirstWhateverTheSaveOrder() async throws {
        let middle = entry("b.wav", at: 2_000), oldest = entry("a.wav", at: 1_000), newest = entry("c.wav", at: 3_000)
        for item in [middle, oldest, newest] { try history.save(item, emptyRecord) }
        #expect(history.entries == [newest, middle, oldest])
        let reopened = TranscriptHistory(directory: directory)
        await reopened.load()
        #expect(reopened.entries == [newest, middle, oldest])
    }

    @Test func deletingRemovesTheTranscriptFiles() async throws {
        let kept = entry("kept.wav", at: 1_000), removed = entry("removed.wav", at: 2_000)
        try history.save(kept, unicodeRecord)
        try history.save(removed, unicodeRecord)
        try history.delete(removed.id)
        #expect(history.entries == [kept])
        #expect(try jsonFiles() == ["\(kept.id.uuidString).json", "\(kept.id.uuidString).transcript.json"].sorted())
        await #expect(throws: (any Error).self) { try await self.history.record(for: removed.id) }

        try history.deleteAll()
        #expect(history.entries.isEmpty)
        #expect(try jsonFiles().isEmpty)
    }

    @Test func skipsUnreadableAndNewerEntriesWithoutDeletingThem() async throws {
        let good = entry("good.wav", at: 1_000)
        try history.save(good, emptyRecord)
        var future = entry("future.wav", at: 2_000)
        future.version = HistoryEntry.currentVersion + 1
        try JSONEncoder().encode(future).write(to: directory.appending(path: "\(future.id.uuidString).json"))
        try Data("not JSON".utf8).write(to: directory.appending(path: "damaged.json"))

        let reopened = TranscriptHistory(directory: directory)
        await reopened.load()
        #expect(reopened.entries == [good])
        #expect(try jsonFiles().contains("damaged.json"))
        #expect(try jsonFiles().contains("\(future.id.uuidString).json"))
    }

    @Test func startsEmptyBeforeAnythingIsSaved() async {
        await history.load()
        #expect(history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@MainActor
final class HistorySelectionTests {
    let history = TranscriptHistory.temporary()
    let directory: URL

    init() { directory = history.directory }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func makeModel() -> TranscriptionModel {
        TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(), history: history)
    }

    @Test func showsSavedTranscriptsAndEmptiesWhenTheShownOneIsDeleted() async throws {
        let first = entry("訪談 café 🎙️.m4a", at: 1_000, language: english)
        let second = entry("second.wav", at: 2_000)
        try history.save(first, unicodeRecord)
        try history.save(second, emptyRecord)
        let model = makeModel()

        await model.select(first.id)
        #expect(model.selection == first.id)
        #expect(model.transcript == unicodeRecord.transcript)
        #expect(model.cues == unicodeRecord.cues)
        #expect(model.fileName == first.fileName)
        #expect(model.audioDuration == first.audioDuration)
        #expect(model.processingTime == first.processingTime)
        #expect(model.detectedLanguage == english)

        await model.select(second.id)
        #expect(model.fileName == "second.wav")
        #expect(model.transcript.isEmpty)
        #expect(model.detectedLanguage == nil)

        model.deleteEntry(second.id)
        #expect(model.selection == nil)
        #expect(model.fileName.isEmpty)
        #expect(model.audioDuration == nil)
        #expect(history.entries == [first])
    }

    @Test func deletingFromAnotherWindowEmptiesThisOne() async throws {
        let shared = entry("shared.wav", at: 1_000)
        let other = entry("other.wav", at: 2_000)
        try history.save(shared, unicodeRecord)
        try history.save(other, emptyRecord)
        let thisWindow = makeModel(), otherWindow = makeModel(), bystander = makeModel()
        await thisWindow.select(shared.id)
        await otherWindow.select(shared.id)
        await bystander.select(other.id)

        otherWindow.deleteEntry(shared.id)
        thisWindow.reconcileWithHistory()
        bystander.reconcileWithHistory()
        #expect(thisWindow.selection == nil)
        #expect(thisWindow.transcript.isEmpty)
        #expect(bystander.selection == other.id)
        #expect(bystander.fileName == "other.wav")
    }

    @Test func clearingHistoryEmptiesTheWindow() async throws {
        let saved = entry("saved.wav", at: 1_000)
        try history.save(saved, unicodeRecord)
        let model = makeModel()
        await model.select(saved.id)
        model.clearHistory()
        #expect(history.entries.isEmpty)
        #expect(model.selection == nil)
        #expect(model.fileName.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test func reportsATranscriptThatCanNoLongerBeRead() async throws {
        let saved = entry("saved.wav", at: 1_000)
        try history.save(saved, unicodeRecord)
        try FileManager.default.removeItem(at: directory.appending(path: "\(saved.id.uuidString).transcript.json"))
        let model = makeModel()
        await model.select(saved.id)
        #expect(model.errorMessage != nil)
        #expect(model.selection == nil)
        #expect(model.fileName.isEmpty)
    }

    @Test func selectingNothingShowsTheEmptyView() async throws {
        let saved = entry("saved.wav", at: 1_000)
        try history.save(saved, unicodeRecord)
        let model = makeModel()
        await model.select(saved.id)
        await model.select(nil)
        #expect(model.selection == nil)
        #expect(model.transcript.isEmpty)
        #expect(model.cues.isEmpty)
    }
}
