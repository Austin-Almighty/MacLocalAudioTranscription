import SwiftUI

/// Saved transcripts, newest first. Selecting one shows it in the window.
struct HistorySidebar: View {
    let model: TranscriptionModel
    @Binding var isImporting: Bool
    @State private var isConfirmingClear = false

    private var history: TranscriptHistory { model.history }

    var body: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { id in Task { await model.select(id) } }
        )) {
            ForEach(history.entries) { entry in
                row(entry)
                    .tag(entry.id)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteEntry(entry.id) }
                    }
            }
            .onDelete { offsets in
                offsets.map { history.entries[$0].id }.forEach(model.deleteEntry)
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            if let selection = model.selection { model.deleteEntry(selection) }
        }
        #endif
        .overlay {
            if history.entries.isEmpty {
                ContentUnavailableView("No Transcripts", systemImage: "clock",
                                       description: Text("Transcripts you create appear here."))
            }
        }
        .navigationTitle("History")
        .toolbar {
            #if os(iOS)
            // On iPhone the list is the first screen, so importing must be possible from here.
            ToolbarItem(placement: .primaryAction) {
                Button("Import Audio…", systemImage: "plus") { isImporting = true }
                    .disabled(model.isBusy)
            }
            #endif
            ToolbarItem {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Clear History…", systemImage: "trash", role: .destructive) { isConfirmingClear = true }
                        .disabled(history.entries.isEmpty)
                }
            }
        }
        .confirmationDialog("Delete all saved transcripts?", isPresented: $isConfirmingClear) {
            Button("Delete All", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This removes every transcript from history on this device. It can’t be undone.")
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(entry.audioDuration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
