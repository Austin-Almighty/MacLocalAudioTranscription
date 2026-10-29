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
        #expect(model.selection == nil)
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
        let applicationDelegate = TranscriptApplicationDelegate()

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
        let applicationDelegate = TranscriptApplicationDelegate()

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
