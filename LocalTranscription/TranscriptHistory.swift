import Foundation
import Observation
import os

/// What the history list shows for one transcription. The transcript itself is stored separately
/// so the list loads quickly however long the recordings are.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    static let currentVersion = 1

    var version = HistoryEntry.currentVersion
    let id: UUID
    let fileName: String
    let date: Date
    let audioDuration: TimeInterval
    let processingTime: TimeInterval
    let language: DetectedLanguage?
    /// When the transcript was last edited, or nil if it is as transcribed.
    var edited: Date?
    /// Names and terms given to Voz for this recording, if any.
    var vocabulary: [String]?
}

/// The full text and timed cues of one transcription.
struct TranscriptRecord: Codable, Equatable, Sendable {
    let transcript: String
    let cues: [SubtitleCue]
}

/// The file operations History uses, so tests can fail one chosen write.
protocol HistoryFiles: Sendable {
    func createDirectory(at url: URL) throws
    func contents(of directory: URL) throws -> [URL]
    func exists(_ url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    /// Replaces the file in one step, so a failed write leaves the previous file whole.
    func write(_ data: Data, to url: URL) throws
    func copy(_ url: URL, to destination: URL) throws
    /// Moves `replacement` over `url`.
    func replace(_ url: URL, with replacement: URL) throws
    func remove(_ url: URL) throws
}

/// The files on disk.
struct DiskFiles: HistoryFiles {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
    func copy(_ url: URL, to destination: URL) throws { try FileManager.default.copyItem(at: url, to: destination) }
    func replace(_ url: URL, with replacement: URL) throws {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
    }
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// Saved transcriptions, shared by every window. Each entry is two JSON files named by its ID;
/// no audio or original file location is kept.
@MainActor
@Observable
final class TranscriptHistory {
    // A fixed folder name rather than the bundle identifier, which may change before release.
    static let shared = TranscriptHistory(directory: URL.applicationSupportDirectory
        .appending(path: "LocalTranscription/History", directoryHint: .isDirectory))
    nonisolated private static let logger = Logger(subsystem: "LocalTranscription", category: "History")

    /// Newest first.
    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let files: any HistoryFiles
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(directory: URL, files: any HistoryFiles = DiskFiles()) {
        self.directory = directory
        self.files = files
    }

    /// Reads the saved entries once; later calls wait for the first.
    func load() async {
        if let loading { return await loading.value }
        let directory = directory, files = files
        let task = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.readEntries(in: directory, files: files)
            }.value
            // Keep anything saved while loading.
            let saved = Set(entries.map(\.id))
            entries = (entries + found.filter { !saved.contains($0.id) }).sorted { $0.date > $1.date }
        }
        loading = task
        await task.value
    }

    func save(_ entry: HistoryEntry, _ record: TranscriptRecord) throws {
        try files.createDirectory(at: directory)
        let encoder = JSONEncoder()
        // Write the transcript first, so a summary never points at a missing transcript, and
        // remove it again if the summary fails, so no transcript is left that the list can’t show.
        try files.write(encoder.encode(record), to: recordURL(entry.id))
        do {
            try files.write(encoder.encode(entry), to: entryURL(entry.id))
        } catch {
            do {
                try files.remove(recordURL(entry.id))
            } catch let cleanup {
                Self.logger.error("Couldn’t remove the transcript of a failed save: \(cleanup.localizedDescription, privacy: .public)")
            }
            throw error
        }
        entries.insert(entry, at: entries.firstIndex { $0.date <= entry.date } ?? entries.endIndex)
    }

    func record(for id: UUID) async throws -> TranscriptRecord {
        let url = recordURL(id), files = files
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(TranscriptRecord.self, from: files.read(url))
        }.value
    }

    /// Keeps the original cue timings available even after edits remove every word of a cue.
    func originalRecord(for id: UUID) throws -> TranscriptRecord {
        let original = originalURL(id)
        let url = files.exists(original) ? original : recordURL(id)
        return try JSONDecoder().decode(TranscriptRecord.self, from: files.read(url))
    }

    /// Whether the transcript as transcribed is still kept, so Revert can restore it.
    func hasOriginal(_ id: UUID) -> Bool { files.exists(originalURL(id)) }

    /// Saves an edited transcript. The first edit keeps a copy of the transcript as transcribed,
    /// so it can be restored.
    func update(_ id: UUID, _ record: TranscriptRecord, editedAt date: Date) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        // Kept only to undo a failed save; an unreadable transcript doesn’t stop the edit.
        let previous: Data?
        do {
            previous = try files.read(recordURL(id))
        } catch {
            Self.logger.error("Couldn’t read the transcript before editing: \(error.localizedDescription, privacy: .public)")
            previous = nil
        }
        let keepsNewOriginal = !files.exists(originalURL(id))
        if keepsNewOriginal {
            try files.copy(recordURL(id), to: originalURL(id))
        }
        var entry = entries[index]
        entry.edited = date
        var wroteRecord = false
        do {
            try files.write(JSONEncoder().encode(record), to: recordURL(id))
            wroteRecord = true
            try files.write(JSONEncoder().encode(entry), to: entryURL(id))
        } catch {
            // Put back the transcript the summary still describes, so every window agrees on it. A new
            // original copy goes only if the transcript wasn’t overwritten or is put back; otherwise it
            // is the last copy of the words as transcribed.
            restore(wroteRecord ? previous : nil, of: id,
                    removingOriginal: keepsNewOriginal && (!wroteRecord || previous != nil))
            throw error
        }
        entries[index] = entry
    }

    /// Undoes a failed update; a failure here is logged, since the caller reports the first one.
    /// Without previous data the transcript stays as it is: either it wasn’t overwritten, or the old
    /// one couldn’t be read, and keeping the new words beats leaving the entry with none.
    private func restore(_ previous: Data?, of id: UUID, removingOriginal: Bool) {
        do {
            if let previous { try files.write(previous, to: recordURL(id)) }
            if removingOriginal { try files.remove(originalURL(id)) }
        } catch {
            Self.logger.error("Couldn’t restore the transcript after a failed edit: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restores the transcript as transcribed and returns it.
    func revert(_ id: UUID) async throws -> TranscriptRecord {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        try files.replace(recordURL(id), with: originalURL(id))
        var entry = entries[index]
        entry.edited = nil
        try files.write(JSONEncoder().encode(entry), to: entryURL(id))
        entries[index] = entry
        return try await record(for: id)
    }

    func delete(_ id: UUID) throws {
        // Remove the transcripts before the summary: if a later removal fails, the entry stays
        // listed and can be deleted again, rather than leaving transcript text the list can’t show.
        for url in [recordURL(id), originalURL(id), entryURL(id)] where files.exists(url) {
            try files.remove(url)
        }
        entries.removeAll { $0.id == id }
    }

    /// Removes every saved transcript file in the folder, including entries that couldn’t be
    /// listed, so nothing remains after the person clears history.
    func deleteAll() throws {
        let found: [URL]
        do {
            found = try files.contents(of: directory)
        } catch CocoaError.fileReadNoSuchFile {
            found = []
        }
        var firstFailure: (any Error)?
        for file in found where file.pathExtension == "json" {
            do {
                try files.remove(file)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        let remaining = Set(((try? files.contents(of: directory)) ?? []).map(\.lastPathComponent))
        entries.removeAll { !remaining.contains("\($0.id.uuidString).json") }
        if let firstFailure { throw firstFailure }
    }

    private func entryURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }
    private func recordURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).transcript.json") }
    // Ends in .transcript.json so loading never mistakes it for a summary.
    private func originalURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).original.transcript.json") }

    /// Unreadable entries are skipped and logged, not deleted, so a newer format or a damaged
    /// file can still be recovered by hand. Only Clear History removes them.
    nonisolated private static func readEntries(in directory: URL, files: any HistoryFiles) -> [HistoryEntry] {
        let found: [URL]
        do {
            found = try files.contents(of: directory)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            logger.error("Couldn’t list history: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let decoder = JSONDecoder()
        return found.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".transcript.json") }
            .compactMap { url in
                do {
                    let entry = try decoder.decode(HistoryEntry.self, from: files.read(url))
                    guard entry.version <= HistoryEntry.currentVersion else {
                        logger.error("Skipped history entry \(url.lastPathComponent, privacy: .public) from a newer version")
                        return nil
                    }
                    return entry
                } catch {
                    logger.error("Skipped unreadable history entry \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
    }
}
