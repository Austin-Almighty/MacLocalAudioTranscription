import DesertAnt
import Foundation
import Observation
import Voz

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
