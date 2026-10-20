import Foundation
import Testing
@testable import LocalTranscription

struct TranscriptDocumentTests {
    @Test(arguments: ["", "A transcript.", "First line\nSecond line\n", "Café — résumé 🎙️"])
    func preservesTextWhenExportedAndRead(text: String) throws {
        let file = TranscriptDocument(text: text).fileWrapper()
        let restored = try TranscriptDocument(fileWrapper: file)
        #expect(restored.text == text)
    }

    @Test func exportsUTF8WithoutABOM() throws {
        let file = TranscriptDocument(text: "你好\n").fileWrapper()
        #expect(file.regularFileContents == Data([0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD, 0x0A]))
    }

    @Test func rejectsInvalidUTF8() {
        let file = FileWrapper(regularFileWithContents: Data([0xFF, 0xFE, 0xFF]))
        #expect(throws: CocoaError.self) { try TranscriptDocument(fileWrapper: file) }
    }

    @Test func rejectsFoldersAsTranscripts() {
        let folder = FileWrapper(directoryWithFileWrappers: [:])
        #expect(throws: CocoaError.self) { try TranscriptDocument(fileWrapper: folder) }
    }
}
