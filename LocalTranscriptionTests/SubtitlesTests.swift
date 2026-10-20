import Foundation
import Testing
import Voz
@testable import LocalTranscription

struct SubtitlesTests {
    private func words(_ items: [(String, TimeInterval, TimeInterval)]) -> [Word] {
        items.map { Word(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func groupsWordsIntoSentences() {
        let cues = Subtitles.cues(from: words([("Hello", 0, 0.5), ("world.", 0.6, 1.0),
                                               ("Next", 1.2, 1.5), ("one?", 1.6, 2.0)]))
        #expect(cues == [SubtitleCue(start: 0, end: 1.0, text: "Hello world."),
                         SubtitleCue(start: 1.2, end: 2.0, text: "Next one?")])
    }

    @Test func splitsAtLongPauses() {
        let cues = Subtitles.cues(from: words([("before", 0, 0.6), ("after", 2.0, 2.6)]))
        #expect(cues.map(\.text) == ["before", "after"])
    }

    @Test func limitsCueDuration() {
        let input = words((0..<30).map { ("word", Double($0) * 0.5, Double($0) * 0.5 + 0.4) })
        let cues = Subtitles.cues(from: input)
        #expect(cues.count > 1)
        #expect(cues.allSatisfy { $0.end - $0.start <= Subtitles.maxCueDuration })
        #expect(cues.map(\.text).joined(separator: " ").replacingOccurrences(of: "\n", with: " ") == Array(repeating: "word", count: 30).joined(separator: " "))
    }

    @Test func wrapsLongCuesIntoTwoLines() throws {
        let input = words((0..<12).map { ("speaking", Double($0) * 0.4, Double($0) * 0.4 + 0.3) })
        let cues = Subtitles.cues(from: input)
        for cue in cues {
            let lines = cue.text.split(separator: "\n")
            #expect(lines.count <= 2)
            #expect(lines.allSatisfy { $0.count <= Subtitles.maxLineLength })
        }
        #expect(try #require(cues.first).text.contains("\n"))
    }

    @Test func givesShortWordsAMinimumDurationWithoutOverlapping() {
        let cues = Subtitles.cues(from: words([("One.", 1.0, 1.0), ("Two.", 1.2, 1.3), ("Three.", 5.0, 5.0)]))
        #expect(cues == [SubtitleCue(start: 1.0, end: 1.2, text: "One."),
                         SubtitleCue(start: 1.2, end: 1.7, text: "Two."),
                         SubtitleCue(start: 5.0, end: 5.5, text: "Three.")])
    }

    @Test func formatsSubRip() {
        let cues = [SubtitleCue(start: 0, end: 2.5, text: "First line"),
                    SubtitleCue(start: 3661.25, end: 3662, text: "Second\nline")]
        #expect(Subtitles.subRip(cues) == """
            1
            00:00:00,000 --> 00:00:02,500
            First line

            2
            01:01:01,250 --> 01:01:02,000
            Second
            line

            """)
    }

    @Test func formatsWebVTT() {
        let cues = [SubtitleCue(start: 0.0004, end: 59.9996, text: "Café 🎙️")]
        #expect(Subtitles.webVTT(cues) == """
            WEBVTT

            00:00:00.000 --> 00:01:00.000
            Café 🎙️

            """)
    }

    @Test func handlesNoSpeech() {
        #expect(Subtitles.cues(from: []).isEmpty)
        #expect(Subtitles.subRip([]) == "")
        #expect(Subtitles.webVTT([]) == "WEBVTT\n")
    }

    @Test(arguments: [(TranscriptFormat.text, "txt"), (.subRip, "srt"), (.webVTT, "vtt")])
    func exportsWithTheRightExtension(format: TranscriptFormat, fileExtension: String) {
        #expect(format.fileExtension == fileExtension)
        #expect(format.contentType.preferredFilenameExtension == fileExtension)
        #expect(TranscriptDocument.writableContentTypes.contains(format.contentType))
    }

    @Test func rendersEachFormat() {
        let cues = [SubtitleCue(start: 0, end: 1, text: "Hi.")]
        #expect(TranscriptFormat.text.render(transcript: "Hi.", cues: cues) == "Hi.")
        #expect(TranscriptFormat.subRip.render(transcript: "Hi.", cues: cues) == Subtitles.subRip(cues))
        #expect(TranscriptFormat.webVTT.render(transcript: "Hi.", cues: cues) == Subtitles.webVTT(cues))
    }
}
