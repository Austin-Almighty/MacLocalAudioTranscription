import AVFoundation
import Foundation
import Testing
@testable import LocalTranscription

/// Stands in for Ear so the language flow runs without a model.
struct FakeLanguageIdentifier: LanguageIdentifying {
    var result: DetectedLanguage?
    var failure: (any Error)?

    func identify(_ url: URL) async throws -> DetectedLanguage? {
        if let failure { throw failure }
        return result
    }

    func prepare() async {}
}

struct LanguageCheckTests {
    @Test(arguments: [("zh", true, true), ("ja", true, true), ("zh", false, false),
                      ("en", true, false), ("sv", false, false), ("de", true, false)])
    func warnsOnlyOnReliableUnsupportedLanguages(code: String, reliable: Bool, unsupported: Bool) {
        let language = DetectedLanguage(code: code, confidence: 0.9, isReliable: reliable)
        #expect(language.isUnsupported == unsupported)
    }

    @Test func namesLanguagesForThePerson() {
        let english = DetectedLanguage(code: "en", confidence: 1, isReliable: true)
        #expect(english.name == Locale.current.localizedString(forLanguageCode: "en"))
        #expect(DetectedLanguage(code: "zz-unknown", confidence: 1, isReliable: true).name == "zz-unknown")
    }

    @Test(arguments: ["aiff", "wav", "mp3", "m4a", "aac", "flac", "caf"])
    func readsShortRecordingsWhole(format: String) throws {
        let url = try #require(Bundle(for: LanguageFixtureBundle.self)
            .url(forResource: "speech", withExtension: format, subdirectory: "Fixtures"))
        let audio = try AudioWindows.read(url)
        let seconds = Double(audio.samples.count) / audio.sampleRate
        #expect(seconds > 5.5 && seconds < 6.2)
        #expect(audio.samples.contains { abs($0) > 0.01 })
    }

    @Test func samplesLongRecordingsAcrossTheWholeFile() throws {
        // A ramp from 0 to 1 over seven minutes shows where each segment was taken from.
        let rate = 8_000.0
        let frames = AVAudioFrameCount(420 * rate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = Float(frame) / Float(frames)
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let audio = try AudioWindows.read(url)
        let segment = Int(AudioWindows.segmentSeconds * rate)
        #expect(audio.sampleRate == rate)
        #expect(audio.samples.count == segment * AudioWindows.segmentCount)
        #expect(try #require(audio.samples.first) < 0.001)
        #expect(try #require(audio.samples.last) > 0.999)
        // Segments are evenly spaced, so the middle ones start a fifth of the way along each.
        let starts = stride(from: 0, to: audio.samples.count, by: segment).map { audio.samples[$0] }
        for (index, start) in starts.enumerated() {
            #expect(abs(Double(start) - Double(index) / 5 * (390.0 / 420)) < 0.001)
        }
    }

    @Test func rejectsFilesThatAreNotAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("This is not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try AudioWindows.read(url) }
    }
}

@MainActor
struct LanguageWarningFlowTests {
    private func recording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    @Test func asksBeforeLoadingTheModelForUnsupportedSpeech() async throws {
        let chinese = DetectedLanguage(code: "zh", confidence: 0.97, isReliable: true)
        let model = TranscriptionModel(recognizers: RecognizerStore(),
                                       languages: FakeLanguageIdentifier(result: chinese), history: .temporary())
        let url = try recording()
        defer { try? FileManager.default.removeItem(at: url) }

        await model.transcribe(url)
        #expect(model.languageWarning == LanguageWarning(url: url, language: chinese))
        #expect(!model.isReady)
        #expect(!model.isBusy)
        #expect(model.errorMessage == nil)
        #expect(model.transcript.isEmpty)
        #expect(model.fileName.isEmpty)

        await model.dismissLanguageWarning()
        #expect(model.languageWarning == nil)
        #expect(model.fileName.isEmpty)
        #expect(!model.isReady)
    }

    @Test func doesNotCheckFilesThatFailValidation() async {
        let chinese = DetectedLanguage(code: "zh", confidence: 0.97, isReliable: true)
        let model = TranscriptionModel(recognizers: RecognizerStore(),
                                       languages: FakeLanguageIdentifier(result: chinese), history: .temporary())
        await model.transcribe(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(model.languageWarning == nil)
        #expect(model.errorMessage != nil)
    }

}

@MainActor
struct ImportQueueTests {
    private let chinese = DetectedLanguage(code: "zh", confidence: 0.97, isReliable: true)

    private func recordings(_ count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("queued-\(index)-\(UUID().uuidString).m4a")
            try Data("audio".utf8).write(to: url)
            return url
        }
    }

    @Test func sortsAudioFromOtherFiles() throws {
        let bundle = Bundle(for: LanguageFixtureBundle.self)
        let audio = try ["aiff", "wav", "mp3", "m4a", "aac", "flac", "caf"].map { format in
            try #require(bundle.url(forResource: "speech", withExtension: format, subdirectory: "Fixtures"))
        }
        let notes = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("notes".utf8).write(to: notes)
        defer { try? FileManager.default.removeItem(at: notes) }
        let folder = FileManager.default.temporaryDirectory
        let remote = try #require(URL(string: "https://example.com/speech.wav"))

        let sorted = AudioFiles.partition(audio + [notes, folder, remote])
        #expect(sorted.audio == audio)
        #expect(sorted.rejected == [notes, folder, remote])
    }

    @Test func reportsFilesThatAreNotAudioWithoutQueuingThem() async throws {
        let notes = FileManager.default.temporaryDirectory.appendingPathComponent("meeting notes.txt")
        try Data("notes".utf8).write(to: notes)
        defer { try? FileManager.default.removeItem(at: notes) }
        let model = TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(),
                                       history: .temporary())
        let queued = await model.importFiles([notes])
        #expect(!queued)
        #expect(model.errorMessage?.contains("“meeting notes.txt”") == true)
        #expect(model.queuedCount == 0)
        #expect(!model.isReady)
    }

    @Test func pausesOnALanguageWarningAndContinuesAfterTheDecision() async throws {
        let files = try recordings(3)
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let model = TranscriptionModel(recognizers: RecognizerStore(),
                                       languages: FakeLanguageIdentifier(result: chinese), history: .temporary())

        await model.transcribe(files)
        #expect(model.languageWarning?.url == files[0])
        #expect(model.queuedCount == 2)
        #expect(!model.isBusy)
        #expect(!model.isReady)

        // Cancel skips this file and moves on to the next, which warns too.
        await model.dismissLanguageWarning()
        #expect(model.languageWarning?.url == files[1])
        #expect(model.queuedCount == 1)

        // Files added while paused wait their turn.
        let late = try recordings(1)
        defer { late.forEach { try? FileManager.default.removeItem(at: $0) } }
        await model.transcribe(late)
        #expect(model.languageWarning?.url == files[1])
        #expect(model.queuedCount == 2)

        model.clearQueue()
        await model.dismissLanguageWarning()
        #expect(model.languageWarning == nil)
        #expect(model.queuedCount == 0)
        #expect(!model.isReady)
    }

    @Test func reportsEachFailedFileByName() async throws {
        let folder = FileManager.default.temporaryDirectory
        let missing = folder.appendingPathComponent("missing-\(UUID().uuidString).wav")
        let model = TranscriptionModel(recognizers: RecognizerStore(), languages: FakeLanguageIdentifier(),
                                       history: .temporary())
        await model.transcribe([missing, folder])
        let message = try #require(model.errorMessage)
        #expect(message.contains("“\(missing.lastPathComponent)”"))
        #expect(message.contains("“\(folder.lastPathComponent)”"))
        #expect(model.queuedCount == 0)
        #expect(!model.isBusy)
    }
}

private final class LanguageFixtureBundle: NSObject {}
