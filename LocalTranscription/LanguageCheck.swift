import AVFoundation
import Ear
import Foundation
import os
import Voz

/// The spoken language Ear heard in a recording.
struct DetectedLanguage: Codable, Equatable, Sendable {
    let code: String
    let confidence: Double
    let isReliable: Bool

    var name: String { Locale.current.localizedString(forLanguageCode: code) ?? code }

    /// Whether Voz would likely produce incorrect text for this recording.
    /// Uncertain detections never block transcription.
    var isUnsupported: Bool { isReliable && !Voz.supportedLanguages.contains(code) }
}

protocol LanguageIdentifying: Sendable {
    /// Returns nil when identification isn’t available, such as before its model is downloaded.
    func identify(_ url: URL) async throws -> DetectedLanguage?
    /// Fetches the identification model in the background so later imports can be checked.
    func prepare() async
}

/// Identifies languages with Ear only when its model is already on disk, so checking
/// never delays transcription or needs the network.
struct EarLanguageIdentifier: LanguageIdentifying {
    static let shared = EarLanguageIdentifier()
    private static let logger = Logger(subsystem: "LocalTranscription", category: "Language")

    private let ear = Ear()

    func identify(_ url: URL) async throws -> DetectedLanguage? {
        guard ear.isDownloaded() else { return nil }
        let audio = try AudioWindows.read(url)
        let detection = try await ear.identify(samples: audio.samples, sampleRate: audio.sampleRate)
        guard let code = detection.language else { return nil }
        return DetectedLanguage(code: code, confidence: detection.confidence, isReliable: detection.isReliable)
    }

    private let downloads = DownloadGate()

    func prepare() async {
        guard !ear.isDownloaded() else { return }
        let ear = ear
        await downloads.run {
            do {
                try await ear.download()
            } catch {
                Self.logger.error("Language identification model download failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Runs one download at a time; callers that arrive while it runs wait for it instead of starting another.
private actor DownloadGate {
    private var running: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async -> Void) async {
        if let running { return await running.value }
        let task = Task { await work() }
        running = task
        await task.value
        running = nil
    }
}

/// Reads a bounded, mono sample of a recording for language identification.
enum AudioWindows {
    static let segmentSeconds: Double = 30
    static let segmentCount = 6

    /// Reads short files whole. Longer files are sampled as evenly spaced segments, so a
    /// two-hour recording costs a few minutes of audio instead of the whole file.
    static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let segment = AVAudioFramePosition(segmentSeconds * rate)
        let total = file.length
        guard total > 0 else { throw CocoaError(.fileReadCorruptFile) }

        let starts: [AVAudioFramePosition]
        if total <= segment * AVAudioFramePosition(segmentCount) {
            starts = [0]
        } else {
            let last = total - segment
            starts = (0..<segmentCount).map { last * AVAudioFramePosition($0) / AVAudioFramePosition(segmentCount - 1) }
        }
        let length = starts.count == 1 ? total : segment

        var samples: [Float] = []
        samples.reserveCapacity(Int(length) * starts.count)
        for start in starts {
            file.framePosition = start
            samples += try readMono(file, frames: AVAudioFrameCount(min(length, total - start)))
        }
        return (samples, rate)
    }

    private static func readMono(_ file: AVAudioFile, frames: AVAudioFrameCount) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.read(into: buffer, frameCount: frames)
        guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 { return Array(UnsafeBufferPointer(start: channels[0], count: count)) }
        return (0..<count).map { frame in
            (0..<channelCount).reduce(Float(0)) { $0 + channels[$1][frame] } / Float(channelCount)
        }
    }
}
