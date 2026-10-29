import Foundation
import Observation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import LocalTranscription

@MainActor
struct TranscriptionModelTests {
    @Test func startsWithNoTranscriptOrError() {
        let model = TranscriptionModel(history: .temporary())
        #expect(model.transcript.isEmpty)
        #expect(model.fileName.isEmpty)
        #expect(model.audioDuration == nil)
        #expect(model.processingTime == nil)
        #expect(model.errorMessage == nil)
        #expect(!model.isBusy)
        #expect(!model.isReady)
    }

    @Test(arguments: ["https://example.com/audio.wav", "http://example.com/audio.wav", "ftp://example.com/audio.wav"])
    func rejectsRemoteAudioWithoutLoadingTheModel(address: String) async throws {
        let model = TranscriptionModel(history: .temporary())
        await model.transcribe(try #require(URL(string: address)))
        #expect(model.errorMessage != nil)
        #expect(!model.isBusy)
        #expect(!model.isReady)
        #expect(model.transcript.isEmpty)
        #expect(model.fileName.isEmpty)
    }

    @Test func rejectsMissingFilesAndAllowsRetry() async {
        let model = TranscriptionModel(history: .temporary())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await model.transcribe(missing)
        #expect(model.errorMessage != nil)
        #expect(!model.isBusy)
        await model.transcribe(missing)
        #expect(model.errorMessage != nil)
        #expect(!model.isBusy)
        #expect(!model.isReady)
        #expect(model.fileName.isEmpty)
        #expect(model.audioDuration == nil)
        #expect(model.processingTime == nil)
    }

    @Test func ignoresProgressOutsideATranscription() {
        let model = TranscriptionModel(recognizers: RecognizerStore(), history: .temporary())
        model.reportProgress(0.5, for: 0)
        #expect(model.transcriptionProgress == nil)
        #expect(model.progress == nil)
        #expect(model.cues.isEmpty)
    }

    @Test func ignoresDownloadProgressWithoutADownload() {
        let store = RecognizerStore()
        store.reportDownload(0.5)
        #expect(store.downloadProgress == nil)
        #expect(!store.isLoaded)
    }

    @Test func rejectsDirectoriesAsAudio() async {
        let model = TranscriptionModel(history: .temporary())
        await model.transcribe(FileManager.default.temporaryDirectory)
        #expect(model.errorMessage != nil)
        #expect(!model.isBusy)
        #expect(!model.isReady)
        #expect(model.transcript.isEmpty)
    }
}

struct DisplayFormatTests {
    private let english = Locale(identifier: "en_US")

    @Test(arguments: [(5.79, "5.8 s"), (60, "1m"), (688.19, "11m 28s"), (3600, "1h"), (7325.4, "2h 2m 5s")])
    func formatsRecordingLengths(seconds: TimeInterval, text: String) {
        #expect(DisplayFormat.duration(seconds, locale: english) == text)
    }

    @Test func formatsProcessingTimesWithTwoDecimals() {
        #expect(DisplayFormat.processingTime(0.134, locale: english) == "0.13 s")
        #expect(DisplayFormat.processingTime(7.126, locale: english) == "7.13 s")
        #expect(DisplayFormat.processingTime(75, locale: english) == "1m 15s")
    }

    @Test func followsThePersonsLocale() {
        #expect(DisplayFormat.duration(688.19, locale: Locale(identifier: "zh_TW")) == "11分28秒")
        #expect(DisplayFormat.duration(5.79, locale: Locale(identifier: "de_DE")) == "5,8 s")
    }

    @Test func namesTheSupportedLanguagesInOrder() {
        let names = DisplayFormat.supportedLanguageNames(locale: english)
        #expect(names.count == 25)
        #expect(names.contains("English"))
        #expect(names.contains("Ukrainian"))
        #expect(!names.contains("Chinese"))
        #expect(names == names.sorted())
    }
}

@MainActor
struct ImportErrorTests {
    private func message(for url: URL) async -> String? {
        let model = TranscriptionModel(recognizers: RecognizerStore(), history: .temporary())
        await model.transcribe(url)
        return model.errorMessage
    }

    @Test func explainsWhyAFileCannotBeTranscribed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let locked = folder.appendingPathComponent("locked.wav")
        try Data("audio".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }

        let cases: [(URL, ImportError)] = [
            (try #require(URL(string: "https://example.com/audio.wav")), .notLocal),
            (folder.appendingPathComponent("gone.wav"), .missing),
            (folder, .folder),
            (locked, .unreadable),
        ]
        for (url, error) in cases {
            let message = try #require(await message(for: url))
            #expect(message.contains("“\(url.lastPathComponent)”"))
            #expect(message.contains(try #require(error.errorDescription)))
        }
    }
}

struct VocabularyTests {
    @Test func splitsOnCommasAndLineBreaksKeepingPhrasesAndCase() {
        #expect(Vocabulary.terms(from: "SoFi, Patek   Philippe\nKubernetes,, SoFi ,  \n\n sofi") == ["SoFi", "Patek Philippe", "Kubernetes", "sofi"])
        #expect(Vocabulary.terms(from: "  ,\n ").isEmpty)
        #expect(Vocabulary.terms(from: "訪談, café 🎙️") == ["訪談", "café 🎙️"])
    }
}

@MainActor
struct VocabularyQueueTests {
    @Test func eachImportKeepsTheVocabularyEnteredWhenItWasQueued() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let chinese = DetectedLanguage(code: "zh", confidence: 0.97, isReliable: true)
        let model = TranscriptionModel(recognizers: RecognizerStore(),
                                       languages: FakeLanguageIdentifier(result: chinese), history: .temporary())
        model.vocabularyText = "Siobhan, Patek Philippe"
        await model.transcribe(file)
        model.vocabularyText = "Something else"
        #expect(model.languageWarning?.vocabulary == ["Siobhan", "Patek Philippe"])
        #expect(model.vocabulary == ["Something else"])
    }
}

@MainActor
final class TranscriptionEditingSafetyTests {
    let history = TranscriptHistory.temporary()
    let directory: URL
    private var selectionDuringRevert: Task<Void, Never>?

    init() { directory = history.directory }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func entry(_ name: String) -> HistoryEntry {
        HistoryEntry(id: UUID(), fileName: name, date: .now, audioDuration: 1,
                     processingTime: 0.1, language: nil)
    }

    private func model() -> TranscriptionModel {
        TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(), history: history)
    }

    @Test func cannotEditOrRevertWhileAnotherTranscriptIsLoading() async throws {
        let first = entry("first.wav"), second = entry("second.wav")
        try history.save(first, TranscriptRecord(transcript: "First transcript.", cues: []))
        try history.save(second, TranscriptRecord(transcript: "Original second transcript.", cues: []))
        // A long transcript keeps the background JSON decode pending across the main-actor boundary.
        let longTranscript = String(repeating: "Saved second transcript. ", count: 100_000)
        try history.update(second.id, TranscriptRecord(transcript: longTranscript, cues: []), editedAt: .now)
        let model = model()
        await model.select(first.id)
        let selecting = Task { await model.select(second.id) }
        for _ in 0..<100 where !model.isLoadingSelection { await Task.yield() }
        try #require(model.isLoadingSelection)
        #expect(model.transcript == "First transcript.")
        #expect(!model.canEdit)
        model.beginEditing()
        #expect(!model.isEditing)
        await model.revertToOriginal()
        await selecting.value

        #expect(model.canEdit)
        #expect(model.transcript == longTranscript)
        #expect(try await history.record(for: second.id).transcript == longTranscript)
    }

    @Test func failedWritesKeepTheDraftAndBlockDoneSelectionAndRevert() async throws {
        let first = entry("first.wav"), second = entry("second.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        try history.save(second, TranscriptRecord(transcript: "Second transcript.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: history.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: history.directory.path) }

        #expect(!model.saveDraft())
        #expect(!model.endEditing())
        await model.select(second.id)
        await model.revertToOriginal()
        #expect(model.isEditing)
        #expect(model.draft == "Unsaved words.")
        #expect(model.selection == first.id)
        #expect(model.transcript == "Original words.")
        #expect(try await history.record(for: first.id).transcript == "Original words.")
        #expect(model.editSaveError != nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: history.directory.path)
        #expect(model.endEditing())
        #expect(!model.isEditing)
        #expect(try await history.record(for: first.id).transcript == "Unsaved words.")
    }

    @Test func editingDuringRevertCannotRestoreTheOldDraft() async throws {
        let saved = entry("saved.wav")
        let original = TranscriptRecord(transcript: "Original words.", cues: [])
        try history.save(saved, original)
        try history.update(saved.id, TranscriptRecord(transcript: "Old edited words.", cues: []), editedAt: .now)
        let model = model()
        await model.select(saved.id)
        // Observation runs synchronously during the restore, before its record read completes.
        withObservationTracking {
            _ = history.entries
        } onChange: {
            MainActor.assumeIsolated {
                #expect(model.isLoadingSelection)
                #expect(!model.canEdit)
                model.beginEditing()
            }
        }

        await model.revertToOriginal()
        #expect(!model.isEditing)
        #expect(!model.isLoadingSelection)
        #expect(model.canEdit)
        #expect(model.endEditing())
        #expect(model.transcript == original.transcript)
        #expect(try await history.record(for: saved.id) == original)
    }

    @Test func failedRevertReleasesTheLoadingGuard() async throws {
        let saved = entry("saved.wav")
        try history.save(saved, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(saved.id)

        await model.revertToOriginal()

        #expect(!model.isLoadingSelection)
        #expect(model.canEdit)
        #expect(model.errorMessage != nil)
        model.beginEditing()
        #expect(model.isEditing)
        #expect(model.endEditing())
    }

    @Test func selectingAnotherEntryDuringRevertKeepsTheNewSelection() async throws {
        let saved = entry("saved.wav"), other = entry("other.wav")
        try history.save(saved, TranscriptRecord(transcript: "Original words.", cues: []))
        try history.update(saved.id, TranscriptRecord(transcript: "Old edited words.", cues: []), editedAt: .now)
        try history.save(other, TranscriptRecord(transcript: "Other transcript.", cues: []))
        let model = model()
        await model.select(saved.id)
        withObservationTracking {
            _ = history.entries
        } onChange: {
            MainActor.assumeIsolated {
                self.selectionDuringRevert = Task { await model.select(other.id) }
            }
        }

        await model.revertToOriginal()
        await (try #require(selectionDuringRevert)).value

        #expect(model.selection == other.id)
        #expect(model.transcript == "Other transcript.")
        #expect(!model.isLoadingSelection)
        #expect(model.canEdit)
        #expect(try await history.record(for: saved.id).transcript == "Original words.")
    }

    @Test func finishedRecordingIsSavedWithoutReplacingAnUnsavableDraft() async throws {
        let first = entry("first.wav"), finished = entry("finished.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        // Only this entry fails to save; other recordings can still be stored.
        let backup = history.directory.appending(path: "\(first.id.uuidString).original.transcript.json")
        try Data("invalid JSON".utf8).write(to: backup)
        let completed = TranscriptRecord(transcript: "New recording.", cues: [])
        model.finishTranscription(finished, record: completed)

        #expect(model.selection == first.id)
        #expect(model.draft == "Unsaved words.")
        #expect(model.transcript == "Original words.")
        #expect(try await history.record(for: finished.id) == completed)
        #expect(history.entries.contains { $0.id == finished.id })
        try FileManager.default.removeItem(at: backup)
        #expect(model.endEditing())
    }

    @Test func discardingAnUnsavableDraftLetsThePersonMoveOn() async throws {
        let first = entry("first.wav"), other = entry("other.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        try history.save(other, TranscriptRecord(transcript: "Other transcript.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        let backup = history.directory.appending(path: "\(first.id.uuidString).original.transcript.json")
        try Data("invalid JSON".utf8).write(to: backup)

        await model.select(other.id)
        #expect(model.selection == first.id)
        #expect(model.isEditing)
        #expect(model.editSaveError != nil)

        model.discardDraft()
        #expect(!model.isEditing)
        #expect(model.editSaveError == nil)
        #expect(model.transcript == "Original words.")
        await model.select(other.id)
        #expect(model.selection == other.id)
        #expect(model.transcript == "Other transcript.")
        #expect(try await history.record(for: first.id).transcript == "Original words.")
    }

    @Test func repeatedAutosaveFailuresAreReportedOnce() async throws {
        let first = entry("first.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        model.autosaveDraft()
        #expect(model.editSaveError != nil)
        model.keepEditing()
        #expect(model.editSaveError == nil)
        model.autosaveDraft()
        model.autosaveDraft()
        #expect(model.editSaveError == nil)
        #expect(model.errorMessage == nil)
        // Done, switching, closing, and quitting always ask again.
        #expect(!model.endEditing())
        #expect(model.editSaveError != nil)
        #expect(model.draft == "Unsaved words.")
    }

    @Test func aRecordingThatCannotBeSavedWaitsUntilEditingEnds() async throws {
        let first = entry("first.wav"), finished = entry("finished.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let completed = TranscriptRecord(transcript: "New recording.", cues: [])
        model.finishTranscription(finished, record: completed)

        #expect(model.selection == first.id)
        #expect(model.draft == "Unsaved words.")
        #expect(!history.entries.contains { $0.id == finished.id })

        model.discardDraft()
        #expect(model.transcript == "New recording.")
        #expect(model.fileName == "finished.wav")
        #expect(model.selection == nil)
        #expect(model.errorMessage?.contains("“finished.wav” couldn’t be saved to history") == true)
    }

    @Test func aWaitingRecordingIsShownOnceTheDraftSaves() async throws {
        let first = entry("first.wav"), finished = entry("finished.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Saved later.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(finished, record: TranscriptRecord(transcript: "New recording.", cues: []))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(model.endEditing())
        #expect(try await history.record(for: first.id).transcript == "Saved later.")
        #expect(model.transcript == "New recording.")
        // Saving is retried once editing ends, so the recording is now in History.
        #expect(model.selection == finished.id)
        #expect(history.entries.contains { $0.id == finished.id })
    }

    @Test func switchingEntriesFirstShowsAWaitingRecording() async throws {
        let first = entry("first.wav"), other = entry("other.wav"), finished = entry("finished.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        try history.save(other, TranscriptRecord(transcript: "Other transcript.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Saved later.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(finished, record: TranscriptRecord(transcript: "New recording.", cues: []))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        await model.select(other.id)
        #expect(model.transcript == "New recording.")
        await model.select(other.id)
        #expect(model.transcript == "Other transcript.")
    }

    // MARK: Likely bugs from FAILURE_SCENARIOS.md

    /// Scenario 1: neither recording may be lost when both arrive while a draft and History are unwritable.
    @Test func twoRecordingsWaitingOnAnUnsavableDraftAreBothKept() async throws {
        let first = entry("first.wav"), a = entry("a.wav"), b = entry("b.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Saved later.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(a, record: TranscriptRecord(transcript: "Recording A.", cues: []))
        model.finishTranscription(b, record: TranscriptRecord(transcript: "Recording B.", cues: []))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(model.endEditing())
        let kept = Set(history.entries.map(\.fileName)).union([model.fileName])
        #expect(kept.contains("b.wav"))
        #expect(kept.contains("a.wav"))
    }

    /// Scenario 2: a second window editing the same entry must not silently overwrite the first window’s saved edit.
    @Test func editsFromTwoWindowsOnOneEntryAreNotSilentlyOverwritten() async throws {
        let shared = entry("shared.wav")
        try history.save(shared, TranscriptRecord(transcript: "Original words.", cues: []))
        let windowA = model(), windowB = model()
        await windowA.select(shared.id)
        await windowB.select(shared.id)
        windowA.beginEditing()
        windowB.beginEditing()

        windowA.updateDraft("Words from window A.")
        #expect(windowA.endEditing())
        windowB.updateDraft("Words from window B.")
        let savedB = windowB.endEditing()

        let onDisk = try await history.record(for: shared.id).transcript
        // Either A’s edit survives, or B is told its save conflicts instead of overwriting it.
        #expect(onDisk == "Words from window A." || !savedB)
    }

    @Test func waitingRecordingsThatStillCannotBeSavedAreNamed() async throws {
        let first = entry("first.wav"), a = entry("a.wav"), b = entry("b.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(a, record: TranscriptRecord(transcript: "Recording A.", cues: []))
        model.finishTranscription(b, record: TranscriptRecord(transcript: "Recording B.", cues: []))

        model.discardDraft()
        #expect(model.fileName == "b.wav")
        #expect(model.errorMessage?.contains("“a.wav”") == true)
        #expect(model.errorMessage?.contains("“b.wav”") == true)
    }

    @Test func aConflictingEditAsksAndCanKeepEitherVersion() async throws {
        let shared = entry("shared.wav")
        try history.save(shared, TranscriptRecord(transcript: "Original words.", cues: []))
        let windowA = model(), windowB = model()
        await windowA.select(shared.id)
        await windowB.select(shared.id)
        windowA.beginEditing()
        windowB.beginEditing()
        windowA.updateDraft("Words from window A.")
        #expect(windowA.endEditing())
        windowB.updateDraft("Words from window B.")

        #expect(!windowB.endEditing())
        #expect(windowB.editConflict)
        #expect(try await history.record(for: shared.id).transcript == "Words from window A.")

        windowB.keepMyVersion()
        #expect(!windowB.editConflict)
        #expect(try await history.record(for: shared.id).transcript == "Words from window B.")
        #expect(windowB.endEditing())

        // Window A now edits from an outdated version and takes the other one.
        windowA.beginEditing()
        windowA.updateDraft("Late words from A.")
        #expect(!windowA.endEditing())
        windowA.useOtherVersion()
        #expect(!windowA.isEditing)
        #expect(!windowA.editConflict)
        try await Task.sleep(for: .milliseconds(200))
        #expect(windowA.transcript == "Words from window B.")
        #expect(try await history.record(for: shared.id).transcript == "Words from window B.")
    }

    @Test func aWindowsOwnSavesNeverConflict() async throws {
        let saved = entry("saved.wav")
        try history.save(saved, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(saved.id)
        model.beginEditing()
        model.updateDraft("First save.")
        #expect(model.saveDraft())
        model.updateDraft("Second save.")
        #expect(model.endEditing())
        model.beginEditing()
        model.updateDraft("After reopening.")
        #expect(model.endEditing())
        #expect(!model.editConflict)
        #expect(try await history.record(for: saved.id).transcript == "After reopening.")
    }

    // MARK: Review findings after PR #5

    /// A recording History couldn’t store stays kept when a newer recording replaces it on screen.
    @Test func anUnsavedRecordingIsKeptWhenANewerOneReplacesIt() async throws {
        let first = entry("first.wav"), a = entry("a.wav"), b = entry("b.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Saved later.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(a, record: TranscriptRecord(transcript: "Recording A.", cues: []))
        // The draft saves but editing stays open, so A keeps waiting.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(model.saveDraft())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        model.finishTranscription(b, record: TranscriptRecord(transcript: "Recording B.", cues: []))

        #expect(model.fileName == "b.wav")
        #expect(model.unsavedResults.map(\.entry.fileName) == ["a.wav", "b.wav"])
        #expect(model.errorMessage?.contains("“a.wav”") == true)

        // Without editing, a newer recording doesn’t drop the one on screen either.
        let c = entry("c.wav")
        model.finishTranscription(c, record: TranscriptRecord(transcript: "Recording C.", cues: []))
        #expect(model.unsavedResults.map(\.entry.fileName) == ["a.wav", "b.wav", "c.wav"])

        // Once History is writable again, the next recording saves the kept ones too.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        model.finishTranscription(entry("d.wav"), record: TranscriptRecord(transcript: "Recording D.", cues: []))
        #expect(model.unsavedResults.isEmpty)
        #expect(Set(history.entries.map(\.fileName)).isSuperset(of: ["a.wav", "b.wav", "c.wav", "d.wav"]))
    }

    @Test func selectingAnotherEntryKeepsAnUnsavedRecording() async throws {
        let other = entry("other.wav")
        try history.save(other, TranscriptRecord(transcript: "Other transcript.", cues: []))
        let model = model()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(entry("unsaved.wav"), record: TranscriptRecord(transcript: "Only on screen.", cues: []))

        await model.select(other.id)
        #expect(model.transcript == "Other transcript.")
        #expect(model.unsavedResults.map(\.entry.fileName) == ["unsaved.wav"])
    }

    /// A recording with no recognized speech isn’t saved, so it must not look like a saved, editable entry.
    @Test func aRecordingWithNoSpeechIsShownUnselected() {
        let model = model()
        model.finishTranscription(entry("silent.wav"), record: TranscriptRecord(transcript: "  ", cues: []))
        #expect(model.fileName == "silent.wav")
        #expect(model.selection == nil)
        #expect(!model.canEdit)
        #expect(model.unsavedResults.isEmpty)
        #expect(history.entries.isEmpty)
    }

    @Test func exportingUnsavedRecordingsWritesThemAndForgetsOnlyThose() throws {
        let model = model()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(entry("talk.wav"), record: TranscriptRecord(transcript: "First talk.", cues: []))
        model.finishTranscription(entry("talk.wav"), record: TranscriptRecord(transcript: "Second talk.", cues: []))
        let asked = model.unsavedResults
        // A recording that arrives while the save panel is open wasn’t part of what was saved.
        model.finishTranscription(entry("late.wav"), record: TranscriptRecord(transcript: "Late talk.", cues: []))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let written = try model.exportUnsavedResults(asked, to: folder)
        #expect(written.map(\.lastPathComponent) == ["talk.txt", "talk 2.txt"])
        #expect(try String(contentsOf: written[0], encoding: .utf8) == "First talk.")
        #expect(try String(contentsOf: written[1], encoding: .utf8) == "Second talk.")
        #expect(model.unsavedResults.map(\.entry.fileName) == ["late.wav"])

        model.discardUnsavedResults(model.unsavedResults)
        #expect(model.unsavedResults.isEmpty)
    }

    /// Saving the unsaved recording on screen with Save Transcript… keeps its words, so closing and
    /// quitting stop asking about it; a recording that arrives while the save panel is open stays kept.
    @Test func exportingTheShownUnsavedRecordingForgetsOnlyThatOne() throws {
        let model = model()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let a = entry("a.wav"), b = entry("b.wav")
        model.finishTranscription(a, record: TranscriptRecord(transcript: "Recording A.", cues: []))
        let exporting = model.shownUnsavedID
        #expect(exporting == a.id)

        // B finishes while the save panel for A is open, and replaces A on screen.
        model.finishTranscription(b, record: TranscriptRecord(transcript: "Recording B.", cues: []))
        model.forgetExportedRecording(exporting)
        #expect(model.unsavedResults.map(\.entry.fileName) == ["b.wav"])
        #expect(model.shownUnsavedID == b.id)

        model.forgetExportedRecording(model.shownUnsavedID)
        #expect(model.unsavedResults.isEmpty)
        #expect(model.shownUnsavedID == nil)
    }

    /// Exporting a saved entry, or anything while the unsaved recording is off screen, forgets nothing.
    @Test func exportingASavedEntryKeepsUnsavedRecordings() async throws {
        let saved = entry("saved.wav")
        try history.save(saved, TranscriptRecord(transcript: "Saved words.", cues: []))
        let model = model()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(entry("unsaved.wav"), record: TranscriptRecord(transcript: "Only kept here.", cues: []))
        await model.select(saved.id)

        #expect(model.shownUnsavedID == nil)
        model.forgetExportedRecording(model.shownUnsavedID)
        #expect(model.unsavedResults.map(\.entry.fileName) == ["unsaved.wav"])
    }

    /// A recording that waited on an unsavable draft counts as shown once editing ends.
    @Test func aWaitingRecordingShownAfterEditingCanBeExported() async throws {
        let first = entry("first.wav"), waiting = entry("waiting.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        model.beginEditing()
        model.updateDraft("Unsaved words.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(waiting, record: TranscriptRecord(transcript: "Waiting.", cues: []))
        #expect(model.shownUnsavedID == nil)

        model.discardDraft()
        #expect(model.fileName == "waiting.wav")
        #expect(model.shownUnsavedID == waiting.id)
        model.forgetExportedRecording(model.shownUnsavedID)
        #expect(model.unsavedResults.isEmpty)
    }

    /// Scenario 15: another window deletes the entry while this window’s Edits Not Saved alert is open.
    @Test func deletingAnEntryElsewhereClearsAnOpenEditSaveError() async throws {
        let shared = entry("shared.wav")
        try history.save(shared, TranscriptRecord(transcript: "Original words.", cues: []))
        let windowA = model(), windowB = model()
        await windowA.select(shared.id)
        await windowB.select(shared.id)
        windowB.beginEditing()
        windowB.updateDraft("Words from window B.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        #expect(!windowB.saveDraft())
        try #require(windowB.editSaveError != nil)

        // History becomes writable again, and window A deletes the entry while B’s alert is open.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        windowA.deleteEntry(shared.id)
        // Each window reconciles when History’s entries change.
        windowB.reconcileWithHistory()

        #expect(windowB.editSaveError == nil)
        #expect(windowB.draft == nil)
        #expect(!windowB.isEditing)
        #expect(windowB.selection == nil)
        #expect(windowB.fileName.isEmpty)
        #expect(!windowB.canEdit)
        // The alert’s buttons may still fire as it closes; neither brings back the entry or the draft.
        windowB.keepEditing()
        windowB.discardDraft()
        windowB.autosaveDraft()
        #expect(windowB.endEditing())
        #expect(!windowB.isEditing)
        #expect(history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(shared.id.uuidString).transcript.json").path))
    }

    #if os(macOS)
    /// Scenario 4 and the alert collision: quitting asks through the injected prompt, not a SwiftUI alert
    /// that another alert could hide, and asks again for a recording that arrived meanwhile.
    @Test func quittingAsksAboutEveryUnsavedRecording() throws {
        let model = model()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = TranscriptWindowDelegate(model: model, originalDelegate: nil) { _, _ in false }
        window.delegate = delegate
        defer { window.delegate = nil; window.close() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        model.finishTranscription(entry("unsaved.wav"), record: TranscriptRecord(transcript: "Only on screen.", cues: []))
        // The failed save is reported by the ordinary error alert, which may still be open.
        try #require(model.errorMessage != nil)

        var asked: [[String]] = []
        let cancelling = TranscriptApplicationDelegate { model, _ in
            asked.append(model.unsavedResults.map(\.entry.fileName))
            return false
        }
        #expect(cancelling.applicationShouldTerminate(.shared) == .terminateCancel)
        #expect(asked == [["unsaved.wav"]])

        var answers = 0
        let discarding = TranscriptApplicationDelegate { model, _ in
            answers += 1
            if answers == 1 {
                let shown = model.unsavedResults
                model.finishTranscription(self.entry("late.wav"), record: TranscriptRecord(transcript: "Late.", cues: []))
                model.discardUnsavedResults(shown)
            } else {
                model.discardUnsavedResults(model.unsavedResults)
            }
            return true
        }
        #expect(discarding.applicationShouldTerminate(.shared) == .terminateNow)
        #expect(answers == 2)
        #expect(model.unsavedResults.isEmpty)
    }

    /// Closing a window, not only quitting, asks before an unsaved recording is lost, including one
    /// that ending the edit has just put on screen.
    @Test func closingAWindowAsksAboutUnsavedRecordings() async throws {
        let first = entry("first.wav")
        try history.save(first, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(first.id)
        var answer = false
        var asked: [[String]] = []
        let delegate = TranscriptWindowDelegate(model: model, originalDelegate: nil) { model, _ in
            asked.append(model.unsavedResults.map(\.entry.fileName))
            if answer { model.discardUnsavedResults(model.unsavedResults) }
            return answer
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        model.beginEditing()
        model.updateDraft("Edited words.")
        // The draft can’t be saved while the recording finishes, so the recording waits.
        let backup = history.directory.appending(path: "\(first.id.uuidString).original.transcript.json")
        try Data("invalid JSON".utf8).write(to: backup)
        // History can’t store this one recording: a folder sits where its file would go.
        let waiting = entry("waiting.wav")
        let blocker = history.directory.appending(path: "\(waiting.id.uuidString).transcript.json")
        try FileManager.default.createDirectory(at: blocker.appending(path: "keep"), withIntermediateDirectories: true)
        model.finishTranscription(waiting, record: TranscriptRecord(transcript: "Waiting.", cues: []))
        try #require(model.isEditing)

        // Ending the edit fails here, so nothing closes or is asked yet.
        #expect(!delegate.windowShouldClose(window))
        #expect(asked.isEmpty)

        // Once the draft saves, ending the edit puts the waiting recording on screen in the same call.
        try FileManager.default.removeItem(at: backup)
        model.keepEditing()
        #expect(!delegate.windowShouldClose(window))
        #expect(!model.isEditing)
        #expect(model.fileName == "waiting.wav")
        #expect(asked == [["waiting.wav"]])
        answer = true
        #expect(delegate.windowShouldClose(window))
        #expect(model.unsavedResults.isEmpty)
    }

    @Test func quittingWithASilentRecordingOnScreenDoesNotAsk() {
        let model = model()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = TranscriptWindowDelegate(model: model, originalDelegate: nil) { _, _ in false }
        window.delegate = delegate
        defer { window.delegate = nil; window.close() }
        model.finishTranscription(entry("silent.wav"), record: TranscriptRecord(transcript: "", cues: []))
        #expect(TranscriptApplicationDelegate { _, _ in false }.applicationShouldTerminate(.shared) == .terminateNow)
    }
    #endif

    #if os(macOS)
    @Test func nativeCloseAndQuitKeepADraftUntilItCanBeSaved() async throws {
        let saved = entry("saved.wav")
        try history.save(saved, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(saved.id)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = TranscriptWindowDelegate(model: model, originalDelegate: nil)
        window.delegate = delegate
        defer { window.delegate = nil; window.close() }
        try #require(NSApplication.shared.windows.contains { $0 === window })
        let applicationDelegate = TranscriptApplicationDelegate { _, _ in false }

        model.beginEditing()
        model.updateDraft("Words that must survive closing.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        #expect(!delegate.windowShouldClose(window))
        #expect(applicationDelegate.applicationShouldTerminate(.shared) == .terminateCancel)
        #expect(model.isEditing)
        #expect(model.draft == "Words that must survive closing.")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(delegate.windowShouldClose(window))
        #expect(!model.isEditing)
        #expect(try await history.record(for: saved.id).transcript == "Words that must survive closing.")

        model.beginEditing()
        model.updateDraft("Words saved while quitting.")
        #expect(applicationDelegate.applicationShouldTerminate(.shared) == .terminateNow)
        #expect(!model.isEditing)
        #expect(try await history.record(for: saved.id).transcript == "Words saved while quitting.")
    }

    @Test func nativeCloseAndQuitSucceedAfterDiscardingAnUnsavableDraft() async throws {
        let saved = entry("saved.wav")
        try history.save(saved, TranscriptRecord(transcript: "Original words.", cues: []))
        let model = model()
        await model.select(saved.id)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = TranscriptWindowDelegate(model: model, originalDelegate: nil)
        window.delegate = delegate
        defer { window.delegate = nil; window.close() }
        let applicationDelegate = TranscriptApplicationDelegate { _, _ in false }

        model.beginEditing()
        model.updateDraft("Words that can’t be saved.")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        #expect(!delegate.windowShouldClose(window))
        #expect(model.editSaveError != nil)

        model.discardDraft()
        #expect(delegate.windowShouldClose(window))
        #expect(applicationDelegate.applicationShouldTerminate(.shared) == .terminateNow)
    }

    @Test func nativeClosePreservesTheOriginalWindowDelegate() {
        let original = CloseVetoDelegate()
        let delegate = TranscriptWindowDelegate(model: model(), originalDelegate: original)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(!delegate.windowShouldClose(window))
        let selector = #selector(NSWindowDelegate.windowDidResize(_:))
        #expect(delegate.responds(to: selector))
        #expect(delegate.forwardingTarget(for: selector) as? CloseVetoDelegate === original)
    }

    @Test func nativeBridgeInstallsAndRestoresTheOriginalWindowDelegate() {
        let original = CloseVetoDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = original
        defer { window.contentView = nil; window.delegate = nil; window.close() }
        let model = model()
        let host = NSHostingView(rootView: TranscriptWindowCloseGuard(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let installed = window.delegate as? TranscriptWindowDelegate
        #expect(installed?.model === model)
        #expect(installed?.originalDelegate === original)
        window.contentView = nil
        #expect(window.delegate === original)
    }
    #endif
}

#if os(macOS)
private final class CloseVetoDelegate: NSObject, NSWindowDelegate {
    @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    @MainActor func windowDidResize(_ notification: Notification) {}
}
#endif
