import CryptoKit
import Foundation
import ObjectiveC
import Voz

// Use the process sandbox in offline.sb; never change the Mac’s network settings.
// The long mode expects the twenty-minute Spanish fixture documented in the check report.
// The interrupt mode kills its own process partway through the model download, like a force quit;
// inspect records the cache it leaves. The drop mode loses the connection partway through a weight
// file while the process keeps running, then retries in the same process.
@main
struct OfflineCheck {
    @MainActor
    static func main() async throws {
        precondition(CommandLine.arguments.count == 4, "Usage: check-offline cold|cached|online|long|interrupt|inspect|drop AUDIO REPORT")
        let mode = CommandLine.arguments[1]
        precondition(["cold", "cached", "online", "long", "interrupt", "inspect", "drop"].contains(mode))
        let audio = URL(fileURLWithPath: CommandLine.arguments[2])
        let report = URL(fileURLWithPath: CommandLine.arguments[3])
        if mode == "inspect" {
            let result: [String: Any] = ["mode": mode, "modelIsDownloaded": Voz.isDownloaded(), "cache": ModelCache.state()]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
            print("PASS: inspect; report: \(report.path)")
            return
        }
        if mode == "drop" { ConnectionDrop.install() }
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
        if !["online", "interrupt", "drop"].contains(mode) { precondition(networkError != nil, "The offline check requires a blocked network probe") }
        let model = TranscriptionModel()
        if mode == "interrupt" {
            precondition(!model.modelIsDownloaded, "Interrupt check must start without a model")
            // Voz v0.4.0 downloads the decoder weights between 93.2% and 96.9% of its bytes.
            let killAt = 0.95
            let preparation = Task { await model.prepare() }
            var fraction = 0.0
            while fraction < killAt {
                try await Task.sleep(for: .milliseconds(2))
                precondition(model.errorMessage == nil, "Download failed before the interruption point")
                precondition(!model.isReady, "Download finished before the interruption point")
                fraction = max(fraction, model.progress ?? 0)
            }
            let result: [String: Any] = [
                "mode": mode,
                "killedAtFraction": fraction,
                "cacheDirectory": FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path,
                "modelIsDownloaded": Voz.isDownloaded(),
                "checkedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
            print("KILLING at \(fraction); report: \(report.path)")
            kill(getpid(), SIGKILL)
            await preparation.value
        }
        if mode == "drop" {
            precondition(!model.modelIsDownloaded, "Drop check must start without a model")
            await model.prepare()
            precondition(ConnectionDrop.droppedAfterBytes > 0, "The connection was never dropped")
            precondition(model.errorMessage != nil && !model.isBusy && !model.isReady && model.progress == nil)
            precondition(!Voz.isDownloaded() && !model.modelIsDownloaded)
            let failed = ModelCache.state()
            let failure = model.errorMessage ?? ""
            await model.prepare()
            precondition(model.errorMessage == nil && model.isReady && !model.isBusy && Voz.isDownloaded())
            await model.transcribe(audio)
            precondition(model.errorMessage == nil && !model.transcript.isEmpty && !model.isBusy)
            let result: [String: Any] = [
                "mode": mode,
                "droppedFile": ConnectionDrop.file,
                "droppedAfterBytes": ConnectionDrop.droppedAfterBytes,
                "firstAttemptError": failure,
                "afterFailure": failed,
                "afterRetry": ModelCache.state(),
                "text": model.transcript,
                "checkedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
            print("PASS: drop; report: \(report.path)")
            return
        }
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

/// The Voz v0.4.0 files in the managed cache, with sizes, hashes, and modification times.
enum ModelCache {
    static func state() -> [String: Any] {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "desert-ant-models/desert-ant-labs/voz/v0.4.0")
        var files: [String: Any] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            files[path] = [
                "size": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "modified": (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            ]
        }
        return ["root": root.path, "files": files]
    }
}

/// Fails the first download of the decoder weights with a lost connection after a few megabytes,
/// by adding a URL protocol to every default session configuration, including the SDK’s.
final class ConnectionDrop: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    static let file = "decoder.mlmodelc/weights/weight.bin"
    static let limit = 6_000_000
    private static let handled = "ConnectionDropHandled"
    nonisolated(unsafe) static var armed = true
    nonisolated(unsafe) static var droppedAfterBytes = 0
    private var inner: URLSession?
    private var received = 0

    static func install() {
        let method = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString("defaultSessionConfiguration"))!
        typealias Original = @convention(c) (AnyClass, Selector) -> URLSessionConfiguration
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyClass) -> URLSessionConfiguration = { type in
            let configuration = original(type, NSSelectorFromString("defaultSessionConfiguration"))
            configuration.protocolClasses = [ConnectionDrop.self] + (configuration.protocolClasses ?? [])
            return configuration
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        armed && property(forKey: handled, in: request) == nil && request.url?.path.hasSuffix(file) == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.armed = false
        let forwarded = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handled, in: forwarded)
        inner = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        inner?.dataTask(with: forwarded as URLRequest).resume()
    }

    override func stopLoading() { inner?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard Self.droppedAfterBytes == 0 else { return }
        client?.urlProtocol(self, didLoad: data)
        received += data.count
        if received >= Self.limit {
            Self.droppedAfterBytes = received
            session.invalidateAndCancel()
            // Carries the description CFNetwork gives this error, which the app shows as is.
            let lost = URLError(.networkConnectionLost, userInfo: [
                NSLocalizedDescriptionKey: "The network connection was lost.",
                NSURLErrorFailingURLErrorKey: request.url as Any,
            ])
            client?.urlProtocol(self, didFailWithError: lost)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard Self.droppedAfterBytes == 0 else { return }
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
}
