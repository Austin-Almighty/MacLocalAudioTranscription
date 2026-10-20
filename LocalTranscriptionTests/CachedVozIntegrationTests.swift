import Foundation
import Testing
import Voz
@testable import LocalTranscription

#if os(macOS) && arch(arm64)
@Suite("Cached Voz integration", .serialized,
       .enabled(if: Voz.isDownloaded(), "Prepare Voz in the app before running real-model tests"))
@MainActor
struct CachedVozIntegrationTests {
    @Test(arguments: ["aiff", "wav", "mp3", "m4a", "aac", "flac", "caf"])
    func transcribesSupportedAudioFormats(format: String) async throws {
        let model = TranscriptionModel()
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
    }

    @Test func acceptsSpacesAndUnicodeInFileNames() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = file.appendingPathComponent("訪談 café 🎙️.aiff")
        try FileManager.default.copyItem(at: fixture("aiff"), to: audio)
        let model = TranscriptionModel()
        try #require(model.modelIsDownloaded)
        await model.transcribe(audio)
        #expect(model.errorMessage == nil)
        #expect(model.fileName == "訪談 café 🎙️.aiff")
        #expect(model.transcript.contains("quick brown fox"))
    }

    @Test func failedImportPreservesThePreviousTranscript() async throws {
        let model = TranscriptionModel()
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
    }

    @Test func recoversFromCorruptAudio() async throws {
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("This is not audio".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        let model = TranscriptionModel()
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
        let model = TranscriptionModel()
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

private final class FixtureBundle: NSObject {}
#endif
