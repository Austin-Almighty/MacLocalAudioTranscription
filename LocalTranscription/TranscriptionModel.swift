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

    @ObservationIgnored private let recognizers: RecognizerStore

    init(recognizers: RecognizerStore = .shared) {
        self.recognizers = recognizers
    }

    var isBusy: Bool { status != nil }

    func prepare() async {
        guard !isBusy else { return }
        status = "Preparing Voz…"
        errorMessage = nil
        defer { status = nil }
        do {
            _ = try await loadModel()
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }

    private func loadModel() async throws -> Voz {
        if !recognizers.isLoaded {
            status = Voz.isDownloaded() ? "Loading Voz…" : "Downloading and preparing Voz…"
        }
        let loaded = try await recognizers.recognizer()
        modelIsDownloaded = true
        isReady = true
        return loaded
    }
}

/// Shares one recognizer across all windows so each window doesn’t load its own copy of the model.
@MainActor
final class RecognizerStore {
    static let shared = RecognizerStore()

    private var loading: Task<Voz, any Error>?
    private(set) var isLoaded = false

    func recognizer() async throws -> Voz {
        if let loading { return try await loading.value }
        // Use the README’s public-API-only configuration before the first model load.
        DesertAnt.fasterNeuralEngineCompile = false
        let task = Task { try await Voz() }
        loading = task
        do {
            let voz = try await task.value
            isLoaded = true
            return voz
        } catch {
            // Let a later request retry after a failed download or load.
            loading = nil
            throw error
        }
    }
}
