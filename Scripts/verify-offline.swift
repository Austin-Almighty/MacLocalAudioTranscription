import Foundation

// Use the process sandbox in offline.sb; never change the Mac’s network settings.
// The long mode expects the twenty-minute Spanish fixture documented in the check report.
@main
struct OfflineCheck {
    @MainActor
    static func main() async throws {
        precondition(CommandLine.arguments.count == 4, "Usage: check-offline cold|cached|online|long AUDIO REPORT")
        let mode = CommandLine.arguments[1]
        precondition(["cold", "cached", "online", "long"].contains(mode))
        let audio = URL(fileURLWithPath: CommandLine.arguments[2])
        let report = URL(fileURLWithPath: CommandLine.arguments[3])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        var networkError: String?
        do {
            _ = try await session.data(from: URL(string: "https://huggingface.co/")!)
        } catch {
            networkError = String(describing: error)
        }
        session.invalidateAndCancel()
        if mode != "online" { precondition(networkError != nil, "The offline check requires a blocked network probe") }
        let model = TranscriptionModel()
        if mode == "cold" {
            precondition(!model.modelIsDownloaded, "Cold check must use an empty cache")
            await model.prepare()
            precondition(model.errorMessage != nil && !model.isBusy && !model.isReady)
        } else {
            if mode == "online" { precondition(!model.modelIsDownloaded, "Online retry must start without a model") }
            else { precondition(model.modelIsDownloaded, "Cached check requires an installed model") }
            await model.prepare()
            precondition(model.errorMessage == nil && model.isReady && !model.isBusy)
            if mode == "long" {
                let transcription = Task { await model.transcribe(audio) }
                for _ in 0..<1000 {
                    if model.isBusy { break }
                    await Task.yield()
                }
                precondition(model.isBusy, "Long recording must enter busy state")
                await model.transcribe(URL(fileURLWithPath: "LocalTranscriptionTests/Fixtures/speech.aiff"))
                await transcription.value
                precondition(model.fileName == audio.lastPathComponent, "Second import must not replace the active recording")
                precondition((model.audioDuration ?? 0) >= 1199)
                precondition(["prueba", "local", "voz", "audio", "servidor"].allSatisfy(model.transcript.lowercased().contains))
            } else {
                await model.transcribe(audio)
            }
            precondition(model.errorMessage == nil && !model.transcript.isEmpty && !model.isBusy)
            precondition((model.audioDuration ?? 0) > 0)
        }
        let result: [String: Any] = [
            "mode": mode,
            "networkProbeBlocked": networkError != nil,
            "networkProbeError": networkError ?? "",
            "cacheDirectory": FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path,
            "isBusy": model.isBusy,
            "isReady": model.isReady,
            "error": model.errorMessage ?? "",
            "text": model.transcript,
            "audioSeconds": model.audioDuration ?? 0,
            "processingSeconds": model.processingTime ?? 0,
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print("PASS: \(mode), network blocked: \(networkError != nil); report: \(report.path)")
    }
}
