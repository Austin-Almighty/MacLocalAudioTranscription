import DesertAnt
import Foundation
import Observation
import Voz

@MainActor
@Observable
final class TranscriptionModel {
    private(set) var transcript = ""
    private(set) var fileName = ""
    private(set) var status: String?
    private(set) var isReady = false
    private(set) var modelIsDownloaded = Voz.isDownloaded()
    private(set) var audioDuration: TimeInterval?
    private(set) var processingTime: TimeInterval?
    var errorMessage: String?

    @ObservationIgnored private var voz: Voz?

    var isBusy: Bool { status != nil }

    func prepare() async {
        guard !isBusy else { return }
        status = "Preparing Voz…"
        errorMessage = nil
        defer { status = nil }
        do {
            _ = try await loadModel()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func transcribe(_ url: URL) async {
        guard !isBusy else { return }
        status = "Opening audio…"
        errorMessage = nil
        defer { status = nil }

        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            guard url.isFileURL,
                  FileManager.default.isReadableFile(atPath: url.path),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadNoPermission)
            }
            let recognizer = try await loadModel()
            status = "Transcribing on device…"
            let result = try await recognizer.transcribe(url)
            transcript = result.text
            fileName = url.lastPathComponent
            audioDuration = result.duration
            processingTime = result.processingTime
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func loadModel() async throws -> Voz {
        if let voz { return voz }
        status = Voz.isDownloaded() ? "Loading Voz…" : "Downloading and preparing Voz…"
        // Use the README’s public-API-only configuration before the first model load.
        DesertAnt.fasterNeuralEngineCompile = false
        let loaded = try await Voz()
        voz = loaded
        modelIsDownloaded = true
        isReady = true
        return loaded
    }
}
