import DesertAnt
import Foundation
import Observation
import Voz

@MainActor
@Observable
final class TranscriptionModel {
    private(set) var transcript = ""
    private(set) var cues: [SubtitleCue] = []
    private(set) var fileName = ""
    private(set) var status: String?
    private(set) var isReady = false
    private(set) var modelIsDownloaded = Voz.isDownloaded()
    private(set) var audioDuration: TimeInterval?
    private(set) var processingTime: TimeInterval?
    private(set) var transcriptionProgress: Double?
    var errorMessage: String?

    @ObservationIgnored private let recognizers: RecognizerStore
    @ObservationIgnored private var operation = 0

    init(recognizers: RecognizerStore = .shared) {
        self.recognizers = recognizers
    }

    var isBusy: Bool { status != nil }

    /// Completed fraction of the current download or transcription, or nil when it can’t be measured.
    var progress: Double? {
        // After the download, preparing for the Neural Engine has no measurable progress. Voz also
        // reports full transcription progress well before decoding finishes, so show a spinner then.
        let current = recognizers.downloadProgress ?? transcriptionProgress
        return current.flatMap { $0 < 1 ? $0 : nil }
    }

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
        operation += 1
        let current = operation
        defer {
            status = nil
            transcriptionProgress = nil
        }

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
            transcriptionProgress = 0
            let result = try await recognizer.transcribe(url) { progress in
                Task { @MainActor [weak self] in
                    self?.reportProgress(progress.fractionCompleted, for: current)
                }
            }
            transcript = result.text
            cues = Subtitles.cues(from: result.words)
            fileName = url.lastPathComponent
            audioDuration = result.duration
            processingTime = result.processingTime
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reportProgress(_ fraction: Double, for operation: Int) {
        // Ignore updates that arrive after their transcription has finished.
        guard operation == self.operation, let current = transcriptionProgress else { return }
        transcriptionProgress = max(current, min(1, fraction))
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
@Observable
final class RecognizerStore {
    static let shared = RecognizerStore()

    @ObservationIgnored private var loading: Task<Voz, any Error>?
    private(set) var isLoaded = false
    /// Completed fraction of the model download, or nil when no download is in progress.
    private(set) var downloadProgress: Double?

    func recognizer() async throws -> Voz {
        if let loading { return try await loading.value }
        // Use the README’s public-API-only configuration before the first model load.
        DesertAnt.fasterNeuralEngineCompile = false
        let downloading = !Voz.isDownloaded()
        if downloading { downloadProgress = 0 }
        defer { downloadProgress = nil }
        let task = Task {
            try await Voz { progress in
                guard downloading else { return }
                Task { @MainActor [weak self] in self?.reportDownload(progress.fraction) }
            }
        }
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

    func reportDownload(_ fraction: Double) {
        // Ignore updates that arrive after the download has finished.
        guard let current = downloadProgress else { return }
        downloadProgress = max(current, min(1, fraction))
    }
}
