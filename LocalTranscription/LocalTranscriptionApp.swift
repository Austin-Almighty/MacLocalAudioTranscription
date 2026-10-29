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
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in sender.windows {
            if let delegate = window.delegate as? TranscriptWindowDelegate, !delegate.model.endEditing() {
                // Bring forward the window asking to discard or keep its edits.
                window.makeKeyAndOrderFront(nil)
                return .terminateCancel
            }
        }
        // A recording History couldn’t store would be lost: ask first in its window.
        for window in sender.windows {
            if let delegate = window.delegate as? TranscriptWindowDelegate, delegate.model.unsavedResultName != nil {
                delegate.model.isConfirmingQuit = true
                window.makeKeyAndOrderFront(nil)
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}
#endif
