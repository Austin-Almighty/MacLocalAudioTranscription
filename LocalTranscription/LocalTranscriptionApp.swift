import os
import SwiftUI

@main
struct LocalTranscriptionApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(TranscriptApplicationDelegate.self) private var applicationDelegate
    @AppStorage("transcriptTextScale") private var transcriptTextScale = 1.0
    @State private var updater = AppUpdater()
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1180, height: 720)
        #if os(macOS)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updater.isChecking ? "Checking for Updates…" : "Check for Updates…") {
                    Task { await updater.checkForUpdates() }
                }
                .disabled(updater.isChecking)
            }
            InspectorCommands()
            CommandGroup(after: .sidebar) {
                Button("Increase Transcript Text Size") {
                    transcriptTextScale = min(3, transcriptTextScale + 0.25)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(transcriptTextScale >= 3)
                Button("Decrease Transcript Text Size") {
                    transcriptTextScale = max(0.75, transcriptTextScale - 0.25)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(transcriptTextScale <= 0.75)
                Button("Actual Transcript Text Size") { transcriptTextScale = 1 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
        #endif
    }
}

#if os(macOS)
final class TranscriptApplicationDelegate: NSObject, NSApplicationDelegate {
    private let confirmLosingUnsaved: UnsavedRecordingsPrompt.Confirm

    override convenience init() { self.init(confirm: UnsavedRecordingsPrompt.confirm) }

    init(confirm: @escaping UnsavedRecordingsPrompt.Confirm) {
        confirmLosingUnsaved = confirm
        super.init()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in sender.windows {
            if let delegate = window.delegate as? TranscriptWindowDelegate, !delegate.model.endEditing() {
                // Bring forward the window asking to discard or keep its edits.
                window.makeKeyAndOrderFront(nil)
                return .terminateCancel
            }
        }
        // Recordings History couldn’t store would be lost: ask in each window that has some.
        for window in sender.windows {
            guard let delegate = window.delegate as? TranscriptWindowDelegate else { continue }
            guard UnsavedRecordingsPrompt.resolve(delegate.model, in: window, confirm: confirmLosingUnsaved) else {
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}

/// Asks before closing or quitting loses recordings History couldn’t store. A native alert, unlike a
/// SwiftUI one, can’t be hidden behind another alert the window is already showing.
@MainActor
enum UnsavedRecordingsPrompt {
    /// Returns whether closing or quitting may go ahead; the recordings were exported or discarded if so.
    typealias Confirm = @MainActor (TranscriptionModel, NSWindow) -> Bool

    private static let logger = Logger(subsystem: "LocalTranscription", category: "History")

    /// Asks until no unsaved recordings remain, since another can finish while the prompt is open.
    static func resolve(_ model: TranscriptionModel, in window: NSWindow, confirm: Confirm) -> Bool {
        while !model.unsavedResults.isEmpty {
            let asked = model.unsavedResults.map(\.entry.id)
            window.makeKeyAndOrderFront(nil)
            guard confirm(model, window) else { return false }
            // Nothing was forgotten, so asking again would only repeat the same question.
            if model.unsavedResults.map(\.entry.id) == asked { break }
        }
        return true
    }

    static func confirm(_ model: TranscriptionModel, in window: NSWindow) -> Bool {
        let results = model.unsavedResults
        let one = results.count == 1
        let names = ListFormatter.localizedString(byJoining: results.map { "“\($0.entry.fileName)”" })
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = one ? "Save the Transcript First?" : "Save the Transcripts First?"
        alert.informativeText = "History couldn’t store the \(one ? "transcript" : "transcripts") of \(names). "
            + "Unless you save \(one ? "it" : "them") as text, \(one ? "it" : "they") will be lost."
        alert.addButton(withTitle: one ? "Save Transcript…" : "Save Transcripts…")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return export(results, from: model)
        case .alertSecondButtonReturn:
            model.discardUnsavedResults(results)
            return true
        default:
            return false
        }
    }

    private static func export(_ results: [TranscriptionModel.UnsavedResult], from model: TranscriptionModel) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the transcripts. Each is saved as a text file."
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        do {
            try model.exportUnsavedResults(results, to: folder)
            return true
        } catch {
            logger.error("Couldn’t export unsaved transcripts: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
            return false
        }
    }
}
#endif
