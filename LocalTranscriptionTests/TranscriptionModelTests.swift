import Foundation
import Testing
@testable import LocalTranscription

@MainActor
struct TranscriptionModelTests {
    @Test func startsWithNoTranscriptOrError() {
        let model = TranscriptionModel()
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
        let model = TranscriptionModel()
        await model.transcribe(try #require(URL(string: address)))
        #expect(model.errorMessage != nil)
        #expect(!model.isBusy)
        #expect(!model.isReady)
        #expect(model.transcript.isEmpty)
        #expect(model.fileName.isEmpty)
    }

    @Test func rejectsMissingFilesAndAllowsRetry() async {
        let model = TranscriptionModel()
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
        let model = TranscriptionModel(recognizers: RecognizerStore())
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
        let model = TranscriptionModel()
        await model.transcribe(FileManager.default.temporaryDirectory)
        #expect(model.errorMessage != nil)
        #expect(!model.isBusy)
        #expect(!model.isReady)
        #expect(model.transcript.isEmpty)
    }
}
