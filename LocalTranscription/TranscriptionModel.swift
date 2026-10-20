import DesertAnt
import Foundation
import Observation
import os
import Voz

/// A recording that sounds like a language Voz doesn’t support, waiting for the person to decide.
struct LanguageWarning: Equatable {
    let url: URL
    let language: DetectedLanguage
}

@MainActor
@Observable
final class TranscriptionModel {
    private static let logger = Logger(subsystem: "LocalTranscription", category: "Language")
    private static let historyLogger = Logger(subsystem: "LocalTranscription", category: "History")

    /// The history entry this window shows, or nil for a new, unsaved, or empty view.
    private(set) var selection: UUID?
    private(set) var transcript = ""
    private(set) var cues: [SubtitleCue] = []
    private(set) var detectedLanguage: DetectedLanguage?
    private(set) var languageWarning: LanguageWarning?
    private(set) var fileName = ""
    private(set) var status: String?
    private(set) var isReady = false
    private(set) var modelIsDownloaded = Voz.isDownloaded()
    private(set) var audioDuration: TimeInterval?
    private(set) var processingTime: TimeInterval?
    private(set) var transcriptionProgress: Double?
    var errorMessage: String?

    @ObservationIgnored private let recognizers: RecognizerStore
    @ObservationIgnored private let languages: any LanguageIdentifying
    @ObservationIgnored private var operation = 0
    @ObservationIgnored private var selectionLoad = 0
    @ObservationIgnored let history: TranscriptHistory

    init(recognizers: RecognizerStore = .shared,
         languages: any LanguageIdentifying = EarLanguageIdentifier.shared,
         history: TranscriptHistory = .shared) {
        self.recognizers = recognizers
        self.languages = languages
        self.history = history
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
        await transcribe(url, language: .identify)
    }

    /// Transcribes the recording behind a language warning despite the warning. Takes the warning
    /// itself because SwiftUI dismisses an alert, clearing the warning, before running its action.
    func transcribeAnyway(_ warning: LanguageWarning) async {
        if languageWarning == warning { languageWarning = nil }
        await transcribe(warning.url, language: .accepted(warning.language))
    }

    /// Keeps the previous transcript and drops the recording behind the language warning.
    func dismissLanguageWarning() {
        languageWarning = nil
    }

    private enum LanguageCheck {
        case identify
        case accepted(DetectedLanguage)
    }

    private func transcribe(_ url: URL, language check: LanguageCheck) async {
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
            let language: DetectedLanguage?
            switch check {
            case .identify:
                status = "Identifying language…"
                language = await identifyLanguage(url)
                // Ask before loading the model, so unsupported speech never costs a model load.
                if let language, language.isUnsupported {
                    languageWarning = LanguageWarning(url: url, language: language)
                    return
                }
            case .accepted(let accepted):
                language = accepted
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
            detectedLanguage = language
            fileName = url.lastPathComponent
            audioDuration = result.duration
            processingTime = result.processingTime
            saveToHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves the transcript just shown. On failure the transcript stays on screen, unsaved.
    private func saveToHistory() {
        let entry = HistoryEntry(id: UUID(), fileName: fileName, date: .now,
                                 audioDuration: audioDuration ?? 0, processingTime: processingTime ?? 0,
                                 language: detectedLanguage)
        selectionLoad += 1
        do {
            try history.save(entry, TranscriptRecord(transcript: transcript, cues: cues))
            selection = entry.id
        } catch {
            selection = nil
            Self.historyLogger.error("Couldn’t save transcript: \(error.localizedDescription, privacy: .public)")
            errorMessage = "The transcript couldn’t be saved to history: \(error.localizedDescription)"
        }
    }

    /// Shows a saved transcript, or the empty view for nil.
    func select(_ id: UUID?) async {
        selectionLoad += 1
        let current = selectionLoad
        guard let id, let entry = history.entries.first(where: { $0.id == id }) else {
            show(nil, nil)
            return
        }
        selection = id
        do {
            let record = try await history.record(for: id)
            // A later selection wins over a slower earlier load.
            guard current == selectionLoad else { return }
            show(entry, record)
        } catch {
            guard current == selectionLoad else { return }
            Self.historyLogger.error("Couldn’t open saved transcript: \(error.localizedDescription, privacy: .public)")
            show(nil, nil)
            errorMessage = "The saved transcript couldn’t be opened: \(error.localizedDescription)"
        }
    }

    func deleteEntry(_ id: UUID) {
        do {
            try history.delete(id)
        } catch {
            Self.historyLogger.error("Couldn’t delete transcript: \(error.localizedDescription, privacy: .public)")
            errorMessage = "The transcript couldn’t be deleted: \(error.localizedDescription)"
        }
        reconcileWithHistory()
    }

    func clearHistory() {
        do {
            try history.deleteAll()
        } catch {
            Self.historyLogger.error("Couldn’t clear history: \(error.localizedDescription, privacy: .public)")
            errorMessage = "History couldn’t be cleared completely: \(error.localizedDescription)"
        }
        reconcileWithHistory()
    }

    /// Returns to the empty view when the shown entry was deleted, including from another window.
    func reconcileWithHistory() {
        guard let selection, !history.entries.contains(where: { $0.id == selection }) else { return }
        selectionLoad += 1
        show(nil, nil)
    }

    private func show(_ entry: HistoryEntry?, _ record: TranscriptRecord?) {
        selection = entry?.id
        transcript = record?.transcript ?? ""
        cues = record?.cues ?? []
        detectedLanguage = entry?.language
        fileName = entry?.fileName ?? ""
        audioDuration = entry?.audioDuration
        processingTime = entry?.processingTime
    }

    func reportProgress(_ fraction: Double, for operation: Int) {
        // Ignore updates that arrive after their transcription has finished.
        guard operation == self.operation, let current = transcriptionProgress else { return }
        transcriptionProgress = max(current, min(1, fraction))
    }

    /// Language identification is advisory: any failure lets transcription continue.
    private func identifyLanguage(_ url: URL) async -> DetectedLanguage? {
        do {
            return try await languages.identify(url)
        } catch {
            Self.logger.error("Language identification failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func loadModel() async throws -> Voz {
        if !recognizers.isLoaded {
            status = Voz.isDownloaded() ? "Loading Voz…" : "Downloading and preparing Voz…"
        }
        let loaded = try await recognizers.recognizer()
        modelIsDownloaded = true
        isReady = true
        let languages = languages
        Task.detached(priority: .utility) { await languages.prepare() }
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
