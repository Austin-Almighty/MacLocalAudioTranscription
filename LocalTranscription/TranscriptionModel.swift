import Foundation
import Observation
import os
import Voz

/// A recording that sounds like a language Voz doesn’t support, waiting for the person to decide.
struct LanguageWarning: Equatable {
    let url: URL
    let language: DetectedLanguage
    var vocabulary: [String] = []
    var identifySpeakers = false
}

@MainActor
@Observable
final class TranscriptionModel {
    private static let logger = Logger(subsystem: "LocalTranscription", category: "Language")
    private static let historyLogger = Logger(subsystem: "LocalTranscription", category: "History")
    private static let speakerLogger = Logger(subsystem: "LocalTranscription", category: "Speakers")

    /// The history entry this window shows, or nil for a new, unsaved, or empty view.
    private(set) var selection: UUID?
    private(set) var transcript = ""
    private(set) var displayTranscript = ""
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
    /// Why the draft couldn’t be saved, while the person chooses to discard it or keep editing.
    private(set) var editSaveError: String?
    /// Another window saved this entry since editing began; saving waits for the person to choose.
    private(set) var editConflict = false
    /// A finished recording History couldn’t store.
    struct UnsavedResult: Sendable {
        let entry: HistoryEntry
        let record: TranscriptRecord
    }
    /// Finished recordings History couldn’t store, oldest first, kept until they’re saved, exported,
    /// or discarded, so closing and quitting can ask first.
    private(set) var unsavedResults: [UnsavedResult] = []
    private(set) var isLoadingSelection = false
    /// Changes whenever the shown transcript’s text does, so views can reset cheaply instead of
    /// comparing the whole transcript.
    private(set) var contentVersion = 0
    private(set) var transcriptionProgress: Double?
    var errorMessage: String?
    /// Names and terms for the recordings imported next, as typed.
    var vocabularyText = ""
    /// Applies to new imports, captured separately for every queued file.
    var identifySpeakers = false
    /// The names and terms used for the shown transcript.
    private(set) var shownVocabulary: [String] = []

    @ObservationIgnored private let recognizers: RecognizerStore
    @ObservationIgnored private let languages: any LanguageIdentifying
    @ObservationIgnored private let speakers: any SpeakerIdentifying
    @ObservationIgnored private var operation = 0
    @ObservationIgnored private var selectionLoad = 0
    @ObservationIgnored private var isProcessingQueue = false
    @ObservationIgnored private var preparing: Task<Void, Never>?
    // The entry being edited, kept apart from `selection`, which a finishing transcription moves.
    @ObservationIgnored private var editingID: UUID?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    // Autosave stays quiet after a failure was reported, so a persistent failure doesn’t nag while typing.
    @ObservationIgnored private var reportedSaveFailure = false
    /// Unsaved recordings that arrived while a draft stayed on screen, shown and reported once editing ends.
    @ObservationIgnored private var waitingResults: [UnsavedResult] = []
    /// The entry’s edited date when this window last loaded or saved it, to notice another window’s save.
    @ObservationIgnored private var editingBase: Date?
    private var queue: [QueuedFile] = []
    @ObservationIgnored let history: TranscriptHistory

    init(recognizers: RecognizerStore = .shared,
         languages: any LanguageIdentifying = EarLanguageIdentifier.shared,
         speakers: any SpeakerIdentifying = WhoSpeakerIdentifier.shared,
         history: TranscriptHistory = .shared) {
        self.recognizers = recognizers
        self.languages = languages
        self.speakers = speakers
        self.history = history
    }

    var isBusy: Bool { status != nil }
    var speakerCount: Int { Set(cues.compactMap(\.speaker)).count }

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
        queue += urls.map { QueuedFile(url: $0, check: .identify, vocabulary: vocabulary, identifySpeakers: identifySpeakers) }
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
        queue += audio.map { QueuedFile(url: $0, check: .identify, vocabulary: vocabulary, identifySpeakers: identifySpeakers) }
        await processQueue()
        return true
    }

    /// Transcribes the recording behind a language warning despite the warning, then continues
    /// with the queue. Takes the warning itself because SwiftUI dismisses an alert, clearing the
    /// warning, before running its action.
    func transcribeAnyway(_ warning: LanguageWarning) async {
        if languageWarning == warning { languageWarning = nil }
        queue.insert(QueuedFile(url: warning.url, check: .accepted(warning.language), vocabulary: warning.vocabulary,
                                identifySpeakers: warning.identifySpeakers), at: 0)
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
        /// Captured when queued, so editing the list affects only later imports.
        let vocabulary: [String]
        let identifySpeakers: Bool
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
            await transcribe(file.url, language: file.check, vocabulary: file.vocabulary, identifySpeakers: file.identifySpeakers)
        }
    }

    private func appendError(_ message: String) {
        errorMessage = errorMessage.map { $0 + "\n\n" + message } ?? message
    }

    /// The names and terms currently entered for the next imports.
    var vocabulary: [String] { Vocabulary.terms(from: vocabularyText) }

    private func transcribe(_ url: URL, language check: LanguageCheck, vocabulary: [String], identifySpeakers: Bool) async {
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
            try ImportError.check(url)
            let language: DetectedLanguage?
            switch check {
            case .identify:
                status = "Identifying language…"
                language = await identifyLanguage(url)
                // Ask before loading the model, so unsupported speech never costs a model load.
                if let language, language.isUnsupported {
                    languageWarning = LanguageWarning(url: url, language: language, vocabulary: vocabulary,
                                                      identifySpeakers: identifySpeakers)
                    return
                }
            case .accepted(let accepted):
                language = accepted
            }
            let recognizer = try await loadModel()
            status = "Transcribing on device…"
            transcriptionProgress = 0
            let result = try await recognizer.transcribe(url, vocabulary: vocabulary) { progress in
                Task { @MainActor [weak self] in
                    self?.reportProgress(progress.fractionCompleted, for: current)
                }
            }
            transcriptionProgress = nil
            let cues = await subtitleCues(from: result.words, url: url, identifySpeakers: identifySpeakers)
            let entry = HistoryEntry(id: UUID(), fileName: url.lastPathComponent, date: .now,
                                     audioDuration: result.duration, processingTime: result.processingTime,
                                     language: language, vocabulary: vocabulary.isEmpty ? nil : vocabulary)
            finishTranscription(entry, record: TranscriptRecord(transcript: result.text, cues: cues))
            prepareLanguageCheck()
        } catch {
            appendError("“\(url.lastPathComponent)” couldn’t be transcribed. \(error.localizedDescription)")
        }
    }

    /// Speaker labeling is optional: a failed download or prediction never loses the transcript.
    func subtitleCues(from words: [Word], url: URL, identifySpeakers: Bool) async -> [SubtitleCue] {
        guard identifySpeakers, !words.isEmpty else { return Subtitles.cues(from: words) }
        let previousStatus = status
        status = "Identifying speakers with Who…"
        defer { status = previousStatus }
        do {
            let turns = try await speakers.identify(url)
            return Subtitles.cues(from: words, speakers: SpeakerAttribution.speakers(for: words, turns: turns))
        } catch {
            Self.speakerLogger.error("Speaker identification failed: \(error.localizedDescription, privacy: .public)")
            appendError("“\(url.lastPathComponent)” was transcribed, but its speakers couldn’t be identified. \(error.localizedDescription)")
            return Subtitles.cues(from: words)
        }
    }

    /// Keeps a completed recording in history even when an unsaved draft must stay on screen.
    /// A recording that can’t be saved either waits on screen until editing ends.
    func finishTranscription(_ entry: HistoryEntry, record: TranscriptRecord) {
        let mayReplace = endEditing()
        // History may be writable again, so earlier recordings get another chance first.
        retryUnsavedResults()
        let saveError = saveResult(entry, record)
        let result = UnsavedResult(entry: entry, record: record)
        if saveError != nil { unsavedResults.append(result) }
        guard mayReplace else {
            if saveError != nil { waitingResults.append(result) }
            return
        }
        showResult(entry, record, error: saveError)
    }

    /// Saves a finished recording to History, returning why it couldn’t be saved. Recordings with
    /// no recognized speech aren’t saved.
    private func saveResult(_ entry: HistoryEntry, _ record: TranscriptRecord) -> String? {
        guard Self.hasSpeech(record) else { return nil }
        do {
            try history.save(entry, record)
            return nil
        } catch {
            Self.historyLogger.error("Couldn’t save transcript: \(error.localizedDescription, privacy: .public)")
            return "The transcript of “\(entry.fileName)” couldn’t be saved to history. \(error.localizedDescription)"
        }
    }

    private static func hasSpeech(_ record: TranscriptRecord) -> Bool {
        !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shows a finished recording. One that wasn’t saved is shown unselected, so it can’t be edited.
    private func showResult(_ entry: HistoryEntry, _ record: TranscriptRecord, error: String?) {
        selectionLoad += 1
        show(entry, record)
        if error != nil || !Self.hasSpeech(record) { selection = nil }
        if let error { appendError(error) }
    }

    /// Retries saving every unsaved recording, returning why each one still couldn’t be saved, by entry ID.
    @discardableResult
    private func retryUnsavedResults() -> [UUID: String] {
        var errors: [UUID: String] = [:]
        unsavedResults = unsavedResults.filter { result in
            guard let error = saveResult(result.entry, result.record) else { return false }
            errors[result.entry.id] = error
            return true
        }
        return errors
    }

    /// Retries saving the recordings that waited on editing, then shows the latest. Earlier ones
    /// that still can’t be saved are named, since only one can stay on screen; they stay kept.
    private func showWaitingResults() {
        guard let latest = waitingResults.last else { return }
        let earlier = waitingResults.dropLast()
        waitingResults = []
        let errors = retryUnsavedResults()
        for result in earlier {
            if let error = errors[result.entry.id] { appendError(error) }
        }
        showResult(latest.entry, latest.record, error: errors[latest.entry.id])
    }

    /// Writes the given unsaved recordings to a folder as plain text, then forgets them. Recordings
    /// that arrived meanwhile stay kept. Returns the files written, which never replace existing ones.
    @discardableResult
    func exportUnsavedResults(_ results: [UnsavedResult], to folder: URL) throws -> [URL] {
        var written: [URL] = []
        for result in results {
            let name = (result.entry.fileName as NSString).deletingPathExtension
            var url = folder.appending(path: name + ".txt")
            var copy = 2
            while FileManager.default.fileExists(atPath: url.path) || written.contains(url) {
                url = folder.appending(path: "\(name) \(copy).txt")
                copy += 1
            }
            let text = TranscriptFormat.text.render(transcript: result.record.transcript, cues: result.record.cues)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            written.append(url)
        }
        discardUnsavedResults(results)
        return written
    }

    /// Forgets the given unsaved recordings, after the person chose to lose or export them.
    func discardUnsavedResults(_ results: [UnsavedResult]) {
        let ids = Set(results.map(\.entry.id))
        unsavedResults.removeAll { ids.contains($0.entry.id) }
        waitingResults.removeAll { ids.contains($0.entry.id) }
    }

    /// Shows a saved transcript, or the empty view for nil. Ignored while busy, because the
    /// running transcription will replace whatever is shown when it finishes.
    func select(_ id: UUID?) async {
        let hadWaitingResult = !waitingResults.isEmpty
        guard endEditing(), !isBusy else { return }
        // Leave an unsaved recording that just appeared on screen, rather than replacing it unseen.
        guard !hadWaitingResult else { return }
        selectionLoad += 1
        let current = selectionLoad
        guard let id, let entry = history.entries.first(where: { $0.id == id }) else {
            show(nil, nil)
            return
        }
        selection = id
        isLoadingSelection = true
        defer { if current == selectionLoad { isLoadingSelection = false } }
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
            stopEditing()
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
            isLoadingSelection = true
            Task {
                defer { if current == selectionLoad { isLoadingSelection = false } }
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
    var canEdit: Bool { selection != nil && !isLoadingSelection }

    func beginEditing() {
        guard canEdit, let selection, draft == nil else { return }
        editingID = selection
        editingBase = editedDate
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
            self?.autosaveDraft()
        }
    }

    /// Saves the draft in the background, reporting only the first of repeated failures.
    func autosaveDraft() {
        saveDraft(reportingFailure: !reportedSaveFailure)
    }

    /// Saves the draft, keeping editing open. Subtitle cues keep their timings.
    @discardableResult
    func saveDraft() -> Bool {
        saveDraft(reportingFailure: true)
    }

    private func saveDraft(reportingFailure: Bool, overwriting: Bool = false) -> Bool {
        autosave?.cancel()
        guard let draft, let id = editingID, draft != transcript else { return true }
        // Another window saved or reverted this entry since editing began: don’t overwrite it unasked.
        if !overwriting, history.entries.first(where: { $0.id == id })?.edited != editingBase {
            if reportingFailure {
                editConflict = true
                reportedSaveFailure = true
            }
            return false
        }
        let now = Date.now
        do {
            let original = try history.originalRecord(for: id)
            let edited = CueAlignment.realign(original.cues, to: draft)
            try history.update(id, TranscriptRecord(transcript: draft, cues: edited), editedAt: now)
            transcript = draft
            displayTranscript = Subtitles.plainText(draft, cues: edited)
            contentVersion += 1
            cues = edited
            editedDate = now
            editingBase = now
            reportedSaveFailure = false
            return true
        } catch {
            Self.historyLogger.error("Couldn’t save edits: \(error.localizedDescription, privacy: .public)")
            if reportingFailure {
                // Replaces, not appends, so retries don’t stack copies of the same message.
                editSaveError = "Your edits to “\(fileName)” couldn’t be saved. \(error.localizedDescription)"
                reportedSaveFailure = true
            }
            return false
        }
    }

    /// Saves the draft and leaves editing.
    @discardableResult
    func endEditing() -> Bool {
        guard saveDraft() else { return false }
        stopEditing()
        return true
    }

    /// Leaves editing without saving, for a draft that can’t be saved. The saved transcript stays.
    func discardDraft() {
        stopEditing()
    }

    /// Dismisses a failed-save report and keeps the draft open for another try.
    func keepEditing() {
        editSaveError = nil
        editConflict = false
    }

    /// Resolves a conflict by saving this window’s draft over the other window’s version.
    func keepMyVersion() {
        editConflict = false
        saveDraft(reportingFailure: true, overwriting: true)
    }

    /// Resolves a conflict by dropping this window’s draft and showing the other window’s version.
    func useOtherVersion() {
        stopEditing()
        reconcileWithHistory()
    }

    private func stopEditing() {
        autosave?.cancel()
        draft = nil
        editingID = nil
        editSaveError = nil
        editConflict = false
        reportedSaveFailure = false
        showWaitingResults()
    }

    /// Restores the shown transcript as it was transcribed.
    func revertToOriginal() async {
        guard !isLoadingSelection, endEditing() else { return }
        guard let id = selection else { return }
        selectionLoad += 1
        let current = selectionLoad
        isLoadingSelection = true
        defer { if current == selectionLoad { isLoadingSelection = false } }
        do {
            let record = try await history.revert(id)
            guard current == selectionLoad, selection == id,
                  let entry = history.entries.first(where: { $0.id == id }) else { return }
            show(entry, record)
        } catch {
            Self.historyLogger.error("Couldn’t revert transcript: \(error.localizedDescription, privacy: .public)")
            guard current == selectionLoad else { return }
            appendError("The original transcript couldn’t be restored. \(error.localizedDescription)")
        }
    }

    private func show(_ entry: HistoryEntry?, _ record: TranscriptRecord?) {
        isLoadingSelection = false
        contentVersion += 1
        selection = entry?.id
        transcript = record?.transcript ?? ""
        cues = record?.cues ?? []
        displayTranscript = Subtitles.plainText(transcript, cues: cues)
        detectedLanguage = entry?.language
        fileName = entry?.fileName ?? ""
        audioDuration = entry?.audioDuration
        processingTime = entry?.processingTime
        editedDate = entry?.edited
        shownVocabulary = entry?.vocabulary ?? []
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
