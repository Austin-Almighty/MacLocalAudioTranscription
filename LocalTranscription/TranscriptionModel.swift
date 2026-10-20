import DesertAnt
import Foundation
import Observation
import os
import UniformTypeIdentifiers
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
    /// When the shown transcript was last edited, or nil if it is as transcribed.
    private(set) var editedDate: Date?
    /// The text being edited, or nil when not editing.
    private(set) var draft: String?
    private(set) var transcriptionProgress: Double?
    var errorMessage: String?

    @ObservationIgnored private let recognizers: RecognizerStore
    @ObservationIgnored private let languages: any LanguageIdentifying
    @ObservationIgnored private var operation = 0
    @ObservationIgnored private var selectionLoad = 0
    @ObservationIgnored private var isProcessingQueue = false
    @ObservationIgnored private var preparing: Task<Void, Never>?
    // The entry being edited, kept apart from `selection`, which a finishing transcription moves.
    @ObservationIgnored private var editingID: UUID?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    private var queue: [QueuedFile] = []
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
        if let preparing { return await preparing.value }
        guard !isBusy, !isProcessingQueue else { return }
        let task = Task { await loadForPreparation() }
        preparing = task
        await task.value
        preparing = nil
    }

    private func loadForPreparation() async {
        status = "Preparing Voz…"
        errorMessage = nil
        defer { status = nil }
        do {
            _ = try await loadModel()
            prepareLanguageCheck()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// How many files are waiting behind the one being transcribed.
    var queuedCount: Int { queue.count }

    func transcribe(_ url: URL) async {
        await transcribe([url])
    }

    /// Queues recordings and transcribes them one at a time; each success is saved to history.
    /// Files added while a transcription runs join the queue.
    func transcribe(_ urls: [URL]) async {
        if !isProcessingQueue && languageWarning == nil { errorMessage = nil }
        queue += urls.map { QueuedFile(url: $0, check: .identify) }
        await processQueue()
    }

    /// Queues dropped or chosen files, reporting any that aren’t audio. Returns whether any were queued.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> Bool {
        let (audio, rejected) = AudioFiles.partition(urls)
        if !rejected.isEmpty {
            let names = rejected.map { "“\($0.lastPathComponent)”" }.formatted(.list(type: .and))
            appendError("\(names) \(rejected.count == 1 ? "isn’t an audio file" : "aren’t audio files") and wasn’t transcribed.")
        }
        guard !audio.isEmpty else { return false }
        queue += audio.map { QueuedFile(url: $0, check: .identify) }
        await processQueue()
        return true
    }

    /// Transcribes the recording behind a language warning despite the warning, then continues
    /// with the queue. Takes the warning itself because SwiftUI dismisses an alert, clearing the
    /// warning, before running its action.
    func transcribeAnyway(_ warning: LanguageWarning) async {
        if languageWarning == warning { languageWarning = nil }
        queue.insert(QueuedFile(url: warning.url, check: .accepted(warning.language)), at: 0)
        await processQueue()
    }

    /// Hides the language warning without deciding; SwiftUI calls this as the alert closes.
    func hideLanguageWarning() {
        languageWarning = nil
    }

    /// Skips the recording behind the language warning, keeping the previous transcript, and
    /// continues with the queue.
    func dismissLanguageWarning() async {
        languageWarning = nil
        await processQueue()
    }

    /// Drops the files that haven’t started yet.
    func clearQueue() {
        queue.removeAll()
    }

    private enum LanguageCheck {
        case identify
        case accepted(DetectedLanguage)
    }

    private struct QueuedFile {
        let url: URL
        let check: LanguageCheck
    }

    /// Transcribes queued files in order. Waits for model preparation, and pauses while a
    /// language warning waits for the person.
    private func processQueue() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }
        if let preparing { await preparing.value }
        while languageWarning == nil, !queue.isEmpty {
            let file = queue.removeFirst()
            await transcribe(file.url, language: file.check)
        }
    }

    private func appendError(_ message: String) {
        errorMessage = errorMessage.map { $0 + "\n\n" + message } ?? message
    }

    private func transcribe(_ url: URL, language check: LanguageCheck) async {
        status = "Opening audio…"
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
            // Save any edits to the entry they belong to before the new result replaces it.
            endEditing()
            transcript = result.text
            cues = Subtitles.cues(from: result.words)
            detectedLanguage = language
            fileName = url.lastPathComponent
            audioDuration = result.duration
            processingTime = result.processingTime
            editedDate = nil
            saveToHistory()
            prepareLanguageCheck()
        } catch {
            appendError("“\(url.lastPathComponent)” couldn’t be transcribed. \(error.localizedDescription)")
        }
    }

    /// Saves the transcript just shown. On failure the transcript stays on screen, unsaved.
    /// Recordings with no recognized speech aren’t saved.
    private func saveToHistory() {
        selectionLoad += 1
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selection = nil
            return
        }
        let entry = HistoryEntry(id: UUID(), fileName: fileName, date: .now,
                                 audioDuration: audioDuration ?? 0, processingTime: processingTime ?? 0,
                                 language: detectedLanguage)
        do {
            try history.save(entry, TranscriptRecord(transcript: transcript, cues: cues))
            selection = entry.id
        } catch {
            selection = nil
            Self.historyLogger.error("Couldn’t save transcript: \(error.localizedDescription, privacy: .public)")
            appendError("The transcript of “\(fileName)” couldn’t be saved to history. \(error.localizedDescription)")
        }
    }

    /// Shows a saved transcript, or the empty view for nil. Ignored while busy, because the
    /// running transcription will replace whatever is shown when it finishes.
    func select(_ id: UUID?) async {
        endEditing()
        guard !isBusy else { return }
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
        if let editingID, !history.entries.contains(where: { $0.id == editingID }) {
            // The entry being edited was deleted, so its draft has nowhere to go.
            autosave?.cancel()
            draft = nil
            self.editingID = nil
        }
        guard let selection else { return }
        guard let entry = history.entries.first(where: { $0.id == selection }) else {
            selectionLoad += 1
            show(nil, nil)
            return
        }
        // Another window edited or reverted this entry: show its version, unless editing here.
        if entry.edited != editedDate, !isEditing {
            selectionLoad += 1
            let current = selectionLoad
            Task {
                do {
                    let record = try await history.record(for: selection)
                    guard current == selectionLoad else { return }
                    show(entry, record)
                } catch {
                    Self.historyLogger.error("Couldn’t reload edited transcript: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: Editing

    var isEditing: Bool { draft != nil }
    /// Only saved transcripts can be edited, because edits are saved to history.
    var canEdit: Bool { selection != nil }

    func beginEditing() {
        guard let selection, draft == nil else { return }
        editingID = selection
        draft = transcript
    }

    func updateDraft(_ text: String) {
        guard draft != nil else { return }
        draft = text
        autosave?.cancel()
        autosave = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return  // Cancelled by newer typing or an explicit save.
            }
            self?.saveDraft()
        }
    }

    /// Saves the draft, keeping editing open. Subtitle cues keep their timings.
    func saveDraft() {
        autosave?.cancel()
        guard let draft, let id = editingID, draft != transcript else { return }
        let edited = CueAlignment.realign(cues, to: draft)
        let now = Date.now
        do {
            try history.update(id, TranscriptRecord(transcript: draft, cues: edited), editedAt: now)
            transcript = draft
            cues = edited
            editedDate = now
        } catch {
            Self.historyLogger.error("Couldn’t save edits: \(error.localizedDescription, privacy: .public)")
            appendError("Your edits to “\(fileName)” couldn’t be saved. \(error.localizedDescription)")
        }
    }

    /// Saves the draft and leaves editing.
    func endEditing() {
        guard isEditing else { return }
        saveDraft()
        draft = nil
        editingID = nil
    }

    /// Restores the shown transcript as it was transcribed.
    func revertToOriginal() async {
        endEditing()
        guard let id = selection else { return }
        do {
            let record = try await history.revert(id)
            guard selection == id, let entry = history.entries.first(where: { $0.id == id }) else { return }
            selectionLoad += 1
            show(entry, record)
        } catch {
            Self.historyLogger.error("Couldn’t revert transcript: \(error.localizedDescription, privacy: .public)")
            appendError("The original transcript couldn’t be restored. \(error.localizedDescription)")
        }
    }

    private func show(_ entry: HistoryEntry?, _ record: TranscriptRecord?) {
        selection = entry?.id
        transcript = record?.transcript ?? ""
        cues = record?.cues ?? []
        detectedLanguage = entry?.language
        fileName = entry?.fileName ?? ""
        audioDuration = entry?.audioDuration
        processingTime = entry?.processingTime
        editedDate = entry?.edited
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
        return loaded
    }

    /// Fetches the language model in the background once Voz is idle, so its download and
    /// compilation never compete with a transcription that is starting.
    private func prepareLanguageCheck() {
        let languages = languages
        Task.detached(priority: .utility) { await languages.prepare() }
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

/// Sorts dropped or chosen files into recordings and everything else.
enum AudioFiles {
    static func partition(_ urls: [URL]) -> (audio: [URL], rejected: [URL]) {
        var audio: [URL] = [], rejected: [URL] = []
        for url in urls {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
            if url.isFileURL, type?.conforms(to: .audio) == true {
                audio.append(url)
            } else {
                rejected.append(url)
            }
        }
        return (audio, rejected)
    }
}
