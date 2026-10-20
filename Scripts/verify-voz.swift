import CoreML
import DesertAnt
import Foundation
import Voz

// Run against the spoken fixture described in README.md, using the built macOS SDK objects.
@main
struct VerifyVoz {
    static func main() async throws {
        precondition(CommandLine.arguments.count == 3, "Usage: verify-voz AUDIO REPORT.json")
        let audio = URL(fileURLWithPath: CommandLine.arguments[1])
        let report = URL(fileURLWithPath: CommandLine.arguments[2])
        precondition(FileManager.default.isReadableFile(atPath: audio.path))
        DesertAnt.fasterNeuralEngineCompile = false

        print("Downloading/verifying Voz \(VozModel.revision)…")
        let directory = try await Voz.download()
        precondition(Voz.isDownloaded(), "The model cache must pass SDK integrity checks")
        print("Model verified: \(directory)")

        let loadStart = Date()
        let voz = try await Voz()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        print("Model loaded in \(loadSeconds) seconds")

        var runs: [[String: Any]] = []
        for _ in 0..<2 {
            let result = try await voz.transcribe(audio)
            let text = result.text.lowercased()
            precondition(["local", "speech", "quick", "brown", "fox", "lazy", "dog"].allSatisfy(text.contains),
                         "The spoken fixture was not recognized: \(result.text)")
            precondition(!result.words.isEmpty && result.duration > 0)
            precondition(result.words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= result.duration })
            runs.append([
                "text": result.text,
                "audioSeconds": result.duration,
                "processingSeconds": result.processingTime,
                "realtimeFactor": result.realtimeFactor,
                "wordCount": result.words.count,
            ])
            print("Transcript: \(result.text)")
            print("Audio: \(result.duration)s; inference: \(result.processingTime)s; speed: \(result.realtimeFactor)x")
        }

        var plans: [String: [String: Int]] = [:]
        for (name, units) in [(VozModel.mel, MLComputeUnits.cpuAndNeuralEngine),
                              (VozModel.encoder, .cpuAndNeuralEngine),
                              (VozModel.decodeStep, .cpuOnly)] {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            let plan = try await MLComputePlan.load(
                contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name),
                configuration: configuration)
            guard case .program(let program) = plan.modelStructure else {
                preconditionFailure("Expected a Core ML program for \(name)")
            }
            var counts: [String: Int] = [:]
            func inspect(_ block: MLModelStructure.Program.Block) {
                for operation in block.operations {
                    if let usage = plan.deviceUsage(for: operation) {
                        let device: String
                        switch usage.preferred {
                        case .neuralEngine: device = "neuralEngine"
                        case .cpu: device = "cpu"
                        case .gpu: device = "gpu"
                        @unknown default: device = "unknown"
                        }
                        counts[device, default: 0] += 1
                    }
                    for nested in operation.blocks { inspect(nested) }
                }
            }
            for function in program.functions.values { inspect(function.block) }
            plans[name] = counts
            print("Core ML preferred devices for \(name): \(counts)")
        }
        precondition((plans[VozModel.encoder]?["neuralEngine"] ?? 0) > 0,
                     "The encoder must have operations assigned to the Neural Engine")

        let result: [String: Any] = [
            "verifiedAt": ISO8601DateFormatter().string(from: Date()),
            "sdkVersion": VozModel.sdkVersion,
            "modelRevision": VozModel.revision,
            "modelDirectory": directory,
            "modelLoadSeconds": loadSeconds,
            "audioFile": audio.path,
            "runs": runs,
            "preferredOperationDevices": plans,
            "deviceEvidence": "Core ML compute plan preferences; runtime trace is recorded separately.",
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: report, options: .atomic)
        print("PASS — report: \(report.path)")
    }
}
