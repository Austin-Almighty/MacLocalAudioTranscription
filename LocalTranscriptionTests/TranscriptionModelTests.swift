import Foundation
import Testing
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
