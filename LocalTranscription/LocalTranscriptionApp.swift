import SwiftUI

@main
struct LocalTranscriptionApp: App {
    #if os(macOS)
    @AppStorage("transcriptTextScale") private var transcriptTextScale = 1.0
    @State private var updater = AppUpdater()
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 980, height: 680)
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
