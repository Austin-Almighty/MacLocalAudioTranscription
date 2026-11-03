import DesertAnt
import Foundation
import Observation
import Voz

/// What Voz recognized in a recording.
struct Transcription: Sendable {
    let text: String
    let words: [Word]
    /// Length of the audio transcribed.
    let duration: TimeInterval
    /// Wall-clock time spent transcribing it.
    let processingTime: TimeInterval
}

/// Transcribes recordings: Voz in the app, a stand-in in tests that run without the model.
protocol Transcribing: AnyObject, Sendable {
    /// Reports progress as a fraction from 0 to 1.
    func transcription(of url: URL, vocabulary: [String],
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Transcription
}

extension Voz: Transcribing {
    func transcription(of url: URL, vocabulary: [String],
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Transcription {
        let result = try await transcribe(url, vocabulary: vocabulary) { progress($0.fractionCompleted) }
        return Transcription(text: result.text, words: result.words, duration: result.duration,
                             processingTime: result.processingTime)
    }
}

/// Shares one recognizer across all windows so each window doesn’t load its own copy of the model.
@MainActor
@Observable
final class RecognizerStore {
    /// Loads the recognizer, downloading its model first if needed and reporting the download’s
    /// completed fraction.
    typealias Loader = @Sendable (_ download: @escaping @Sendable (Double) -> Void) async throws -> any Transcribing

    static let shared = RecognizerStore()

    @ObservationIgnored private let isDownloaded: @Sendable () -> Bool
    @ObservationIgnored private let load: Loader
    @ObservationIgnored private var loading: Task<any Transcribing, any Error>?
    private(set) var isLoaded = false
    /// Completed fraction of the model download, or nil when no download is in progress.
    private(set) var downloadProgress: Double?

    init(isDownloaded: @escaping @Sendable () -> Bool = { Voz.isDownloaded() },
         load: @escaping Loader = { download in try await Voz { download($0.fraction) } }) {
        self.isDownloaded = isDownloaded
        self.load = load
    }

    /// Whether the model is on disk, so loading it needs no download.
    var modelIsDownloaded: Bool { isDownloaded() }

    func recognizer() async throws -> any Transcribing {
        if let loading { return try await loading.value }
        // Use the README’s public-API-only configuration before the first model load.
        DesertAnt.fasterNeuralEngineCompile = false
        let downloading = !isDownloaded()
        if downloading { downloadProgress = 0 }
        defer { downloadProgress = nil }
        let task = Task { [load, weak self] in
            try await load { fraction in
                guard downloading else { return }
                Task { @MainActor in self?.reportDownload(fraction) }
            }
        }
        loading = task
        do {
            let recognizer = try await task.value
            isLoaded = true
            return recognizer
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
