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
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    /// Reads the saved entries once; later calls wait for the first.
    func load() async {
        if let loading { return await loading.value }
        let directory = directory
        let task = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.readEntries(in: directory)
            }.value
            // Keep anything saved while loading.
            let saved = Set(entries.map(\.id))
            entries = (entries + found.filter { !saved.contains($0.id) }).sorted { $0.date > $1.date }
        }
        loading = task
        await task.value
    }

    func save(_ entry: HistoryEntry, _ record: TranscriptRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Write the transcript first, so a summary never points at a missing transcript, and
        // remove it again if the summary fails, so no transcript is left that the list can’t show.
        try encoder.encode(record).write(to: recordURL(entry.id), options: .atomic)
        do {
            try encoder.encode(entry).write(to: entryURL(entry.id), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: recordURL(entry.id))
            throw error
        }
        entries.insert(entry, at: entries.firstIndex { $0.date <= entry.date } ?? entries.endIndex)
    }

    func record(for id: UUID) async throws -> TranscriptRecord {
        let url = recordURL(id)
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(TranscriptRecord.self, from: Data(contentsOf: url))
        }.value
    }

    /// Saves an edited transcript. The first edit keeps a copy of the transcript as transcribed,
    /// so it can be restored.
    func update(_ id: UUID, _ record: TranscriptRecord, editedAt date: Date) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        if !FileManager.default.fileExists(atPath: originalURL(id).path) {
            try FileManager.default.copyItem(at: recordURL(id), to: originalURL(id))
        }
        try JSONEncoder().encode(record).write(to: recordURL(id), options: .atomic)
        var entry = entries[index]
        entry.edited = date
        try JSONEncoder().encode(entry).write(to: entryURL(id), options: .atomic)
        entries[index] = entry
    }

    /// Restores the transcript as transcribed and returns it.
    func revert(_ id: UUID) async throws -> TranscriptRecord {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        _ = try FileManager.default.replaceItemAt(recordURL(id), withItemAt: originalURL(id))
        var entry = entries[index]
        entry.edited = nil
        try JSONEncoder().encode(entry).write(to: entryURL(id), options: .atomic)
        entries[index] = entry
        return try await record(for: id)
    }

    func delete(_ id: UUID) throws {
        // Remove the transcripts before the summary: if a later removal fails, the entry stays
        // listed and can be deleted again, rather than leaving transcript text the list can’t show.
        for url in [recordURL(id), originalURL(id), entryURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        entries.removeAll { $0.id == id }
    }

    /// Removes every saved transcript file in the folder, including entries that couldn’t be
    /// listed, so nothing remains after the person clears history.
    func deleteAll() throws {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            files = []
        }
        var firstFailure: (any Error)?
        for file in files where file.pathExtension == "json" {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        let remaining = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        entries.removeAll { !remaining.contains("\($0.id.uuidString).json") }
        if let firstFailure { throw firstFailure }
    }

    private func entryURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }
    private func recordURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).transcript.json") }
    // Ends in .transcript.json so loading never mistakes it for a summary.
    private func originalURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).original.transcript.json") }

    /// Unreadable entries are skipped and logged, not deleted, so a newer format or a damaged
    /// file can still be recovered by hand. Only Clear History removes them.
    nonisolated private static func readEntries(in directory: URL) -> [HistoryEntry] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            logger.error("Couldn’t list history: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".transcript.json") }
            .compactMap { url in
                do {
                    let entry = try decoder.decode(HistoryEntry.self, from: Data(contentsOf: url))
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
