import Foundation
import Testing
import AVFoundation
import Ear
import Voz
@testable import LocalTranscription

#if os(macOS) && arch(arm64)
@Suite("Cached Voz integration", .serialized,
       .enabled(if: Voz.isDownloaded(), "Prepare Voz in the app before running real-model tests"))
@MainActor
final class CachedVozIntegrationTests {
    let history = TranscriptHistory.temporary()
    let historyDirectory: URL

    init() { historyDirectory = history.directory }
    deinit { try? FileManager.default.removeItem(at: historyDirectory) }

    @Test(arguments: ["aiff", "wav", "mp3", "m4a", "aac", "flac", "caf"])
    func transcribesSupportedAudioFormats(format: String) async throws {
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        try #require(model.modelIsDownloaded)
        let audio = try fixture(format)
        await model.transcribe(audio)
        #expect(model.errorMessage == nil)
        #expect(model.isReady)
        #expect(!model.isBusy)
        #expect(model.fileName == "speech." + format)
        #expect(model.transcript.trimmingCharacters(in: .punctuationCharacters)
                == "This is a local speech recognition test. The quick brown fox jumps over the lazy dog")
        #expect(try #require(model.audioDuration) > 5)
        #expect(try #require(model.audioDuration) < 7)
        #expect(try #require(model.processingTime) > 0)
        #expect(!model.cues.isEmpty)
        #expect(model.cues.allSatisfy { $0.start >= 0 && $0.end >= $0.start })
        #expect(try #require(model.cues.last).end <= (try #require(model.audioDuration)) + Subtitles.minCueDuration)
        #expect(model.transcriptionProgress == nil)
        // The transcript is saved, shown as the selected entry, and reloads exactly.
        let saved = try #require(history.entries.first)
        #expect(history.entries.count == 1)
        #expect(model.selection == saved.id)
        #expect(saved.fileName == "speech." + format)
        #expect(saved.audioDuration == model.audioDuration)
        let record = try await history.record(for: saved.id)
        #expect(record == TranscriptRecord(transcript: model.transcript, cues: model.cues))
    }

    @Test func aResultArrivingMidEditSavesTheDraftToItsOwnEntry() async throws {
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        await model.transcribe(try fixture("aiff"))
        let edited = try #require(model.selection)
        model.beginEditing()
        model.updateDraft("Edited before the next recording finished.")

        await model.transcribe(try fixture("wav"))
        #expect(!model.isEditing)
        #expect(model.fileName == "speech.wav")
        #expect(model.editedDate == nil)
        #expect(model.transcript.contains("quick brown fox"))
        #expect(try await history.record(for: edited).transcript == "Edited before the next recording finished.")
        #expect(history.entries.first(where: { $0.id == edited })?.edited != nil)
        #expect(try await history.record(for: try #require(model.selection)).transcript == model.transcript)
    }

    @Test func doesNotSaveRecordingsWithoutSpeech() async throws {
        let silence = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: silence) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        do {
            let file = try AVAudioFile(forWriting: silence, settings: format.settings)
            try file.write(from: buffer)
        }
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        await model.transcribe(silence)
        try #require(model.errorMessage == nil)
        try #require(model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     "Voz recognized text in silence, so this check doesn’t apply")
        #expect(model.fileName == silence.lastPathComponent)
        #expect(history.entries.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func acceptsSpacesAndUnicodeInFileNames() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = file.appendingPathComponent("訪談 café 🎙️.aiff")
        try FileManager.default.copyItem(at: fixture("aiff"), to: audio)
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        try #require(model.modelIsDownloaded)
        await model.transcribe(audio)
        #expect(model.errorMessage == nil)
        #expect(model.fileName == "訪談 café 🎙️.aiff")
        #expect(model.transcript.contains("quick brown fox"))
    }

    @Test func failedImportPreservesThePreviousTranscript() async throws {
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        try #require(model.modelIsDownloaded)
        await model.transcribe(try fixture("aiff"))
        try #require(model.errorMessage == nil)
        let transcript = model.transcript
        let duration = model.audioDuration
        let time = model.processingTime
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await model.transcribe(missing)
        #expect(model.errorMessage != nil)
        #expect(model.transcript == transcript)
        #expect(model.fileName == "speech.aiff")
        #expect(model.audioDuration == duration)
        #expect(model.processingTime == time)
        #expect(model.isReady)
        #expect(!model.isBusy)
        #expect(history.entries.count == 1)
        #expect(model.selection == history.entries.first?.id)
    }

    @Test func recoversFromCorruptAudio() async throws {
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("This is not audio".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        try #require(model.modelIsDownloaded)
        await model.transcribe(invalid)
        #expect(model.errorMessage != nil)
        #expect(!model.isBusy)
        #expect(model.transcript.isEmpty)
        #expect(model.fileName.isEmpty)
        #expect(model.audioDuration == nil)
        await model.transcribe(try fixture("wav"))
        #expect(model.errorMessage == nil)
        #expect(!model.isBusy)
        #expect(model.fileName == "speech.wav")
        #expect(model.transcript.contains("quick brown fox"))
    }

    @Test func repeatedPreparationKeepsTheTranscript() async throws {
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        try #require(model.modelIsDownloaded)
        await model.transcribe(try fixture("aiff"))
        try #require(model.errorMessage == nil)
        let transcript = model.transcript
        await model.prepare()
        await model.prepare()
        #expect(model.errorMessage == nil)
        #expect(model.isReady)
        #expect(!model.isBusy)
        #expect(model.transcript == transcript)
        #expect(model.fileName == "speech.aiff")
    }

    private func fixture(_ format: String) throws -> URL {
        try #require(Bundle(for: FixtureBundle.self)
            .url(forResource: "speech", withExtension: format, subdirectory: "Fixtures"))
    }
}

@Suite("Cached Ear language check", .serialized,
       .enabled(if: Voz.isDownloaded() && Ear.isDownloaded(),
                "Prepare Voz in the app and let it fetch the language model before running these tests"))
@MainActor
final class CachedEarIntegrationTests {
    let history = TranscriptHistory.temporary()
    let historyDirectory: URL

    init() { historyDirectory = history.directory }
    deinit { try? FileManager.default.removeItem(at: historyDirectory) }

    @Test(arguments: ["aiff", "wav", "mp3", "m4a", "aac", "flac", "caf"])
    func identifiesEnglishAndTranscribes(format: String) async throws {
        let model = TranscriptionModel(languages: EarLanguageIdentifier.shared, history: history)
        await model.transcribe(try fixture("speech", format))
        #expect(model.errorMessage == nil)
        #expect(model.languageWarning == nil)
        #expect(model.detectedLanguage?.code == "en")
        #expect(model.detectedLanguage?.isReliable == true)
        #expect(model.transcript.contains("quick brown fox"))
    }

    @Test func warnsBeforeTranscribingChineseThenTranscribesAnyway() async throws {
        let model = TranscriptionModel(languages: EarLanguageIdentifier.shared, history: history)
        await model.transcribe(try fixture("speech", "aiff"))
        try #require(model.errorMessage == nil)
        let english = model.transcript

        let chinese = try fixture("speech-zh", "m4a")
        await model.transcribe(chinese)
        let warning = try #require(model.languageWarning)
        #expect(warning.url == chinese)
        #expect(warning.language.code == "zh")
        #expect(warning.language.isReliable)
        #expect(!model.isBusy)
        #expect(model.transcript == english)
        #expect(model.fileName == "speech.aiff")
        #expect(model.detectedLanguage?.code == "en")
        // Nothing is saved while the person decides.
        #expect(history.entries.count == 1)
        let englishEntry = model.selection

        // SwiftUI clears the warning when the alert closes, before the button’s action runs.
        model.hideLanguageWarning()
        await model.transcribeAnyway(warning)
        #expect(model.languageWarning == nil)
        #expect(model.errorMessage == nil)
        #expect(!model.isBusy)
        #expect(model.fileName == "speech-zh.m4a")
        #expect(model.detectedLanguage?.code == "zh")
        #expect(model.transcript != english)
        #expect(history.entries.map(\.fileName) == ["speech-zh.m4a", "speech.aiff"])
        #expect(history.entries.first?.language?.code == "zh")
        #expect(model.selection == history.entries.first?.id)

        // The English transcript is still one click away.
        await model.select(englishEntry)
        #expect(model.transcript == english)
        #expect(model.detectedLanguage?.code == "en")
    }

    @Test func transcribesABatchInOrderAndKeepsGoingPastFailures() async throws {
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(), history: history)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")
        await model.transcribe([try fixture("speech", "aiff"), missing, try fixture("speech", "wav"), try fixture("speech", "mp3")])
        #expect(history.entries.map(\.fileName) == ["speech.mp3", "speech.wav", "speech.aiff"])
        #expect(model.errorMessage?.contains("“\(missing.lastPathComponent)”") == true)
        #expect(model.selection == history.entries.first?.id)
        #expect(model.fileName == "speech.mp3")
        #expect(model.queuedCount == 0)
        #expect(!model.isBusy)
    }

    @Test func aLanguageWarningPausesTheBatchUntilDecided() async throws {
        let model = TranscriptionModel(languages: EarLanguageIdentifier.shared, history: history)
        await model.transcribe([try fixture("speech", "aiff"), try fixture("speech-zh", "m4a"), try fixture("speech", "wav")])
        let warning = try #require(model.languageWarning)
        #expect(warning.language.code == "zh")
        #expect(model.queuedCount == 1)
        #expect(history.entries.map(\.fileName) == ["speech.aiff"])

        model.hideLanguageWarning()
        await model.transcribeAnyway(warning)
        #expect(history.entries.map(\.fileName) == ["speech.wav", "speech-zh.m4a", "speech.aiff"])
        #expect(model.queuedCount == 0)
        #expect(model.errorMessage == nil)
        #expect(model.fileName == "speech.wav")
    }

    @Test func transcribesWhenIdentificationFails() async throws {
        let model = TranscriptionModel(languages: FakeLanguageIdentifier(failure: CocoaError(.fileReadCorruptFile)), history: history)
        await model.transcribe(try fixture("speech", "wav"))
        #expect(model.errorMessage == nil)
        #expect(model.languageWarning == nil)
        #expect(model.detectedLanguage == nil)
        #expect(model.transcript.contains("quick brown fox"))
    }

    private func fixture(_ name: String, _ format: String) throws -> URL {
        try #require(Bundle(for: FixtureBundle.self)
            .url(forResource: name, withExtension: format, subdirectory: "Fixtures"))
    }
}

private final class FixtureBundle: NSObject {}
#endif
