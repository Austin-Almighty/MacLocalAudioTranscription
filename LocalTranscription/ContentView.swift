import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @State private var model = TranscriptionModel()
    @State private var isImporting = false
    @State private var isExporting = false
    #if os(macOS)
    @State private var showingInspector = true
    @AppStorage("transcriptTextScale") private var transcriptTextScale = 1.0
    #else
    @State private var showingInspector = false
    #endif

    var body: some View {
        NavigationStack {
            recordingContent
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .navigationTitle(model.fileName.isEmpty ? "Local Transcription" : model.fileName)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import Audio…", systemImage: "plus") { isImporting = true }
                            .keyboardShortcut("o")
                            .help("Import an audio recording (⌘O)")
                            .disabled(model.isBusy)
                    }
                    if #available(macOS 26.0, iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        #if os(macOS)
                        Button("Copy Transcript", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.transcript, forType: .string)
                        }
                        .help("Copy the transcript")
                        .disabled(model.transcript.isEmpty)
                        #endif
                        Button("Save Transcript…", systemImage: "square.and.arrow.down") { isExporting = true }
                            .keyboardShortcut("s")
                            .help("Save the transcript as text (⌘S)")
                            .disabled(model.transcript.isEmpty)
                    }
                    if #available(macOS 26.0, iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Toggle("Recording Info", systemImage: "sidebar.right", isOn: $showingInspector)
                            .help("Show or hide recording info")
                    }
                }
                .inspector(isPresented: $showingInspector) {
                    recordingInfo
                        .inspectorColumnWidth(min: 260, ideal: 280, max: 340)
                }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 480)
        #else
        .frame(minWidth: 300, minHeight: 420)
        #endif
        .task {
            if model.modelIsDownloaded { await model.prepare() }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                Task { await model.transcribe(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: TranscriptDocument(text: model.transcript),
                      contentType: .plainText,
                      defaultFilename: (model.fileName as NSString).deletingPathExtension + ".txt") { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("Local Transcription", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var recordingContent: some View {
        Group {
            if model.fileName.isEmpty {
                ContentUnavailableView {
                    Label("No Recording", systemImage: "waveform")
                } description: {
                    Text("Import an audio recording to create a transcript on your device.")
                } actions: {
                    Button("Import Audio…") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isBusy)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Transcript")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(model.transcript.isEmpty ? "No speech was recognized." : model.transcript)
                            #if os(macOS)
                            .font(.system(size: NSFont.preferredFont(forTextStyle: .title3, options: [:]).pointSize * transcriptTextScale))
                            #else
                            .font(.title3)
                            #endif
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(model.transcript)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color(nsColor: .textBackgroundColor))
        #else
        .background(.background)
        #endif
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let status = model.status {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(status)
                    Text(status).accessibilityAddTraits(.updatesFrequently)
                } else {
                    Image(systemName: "lock.shield")
                        .accessibilityHidden(true)
                    Text("On-device transcription")
                    Spacer(minLength: 8)
                    if let duration = model.audioDuration, let time = model.processingTime {
                        Text(String(format: "%.1f s audio · %.2f s processing", duration, time))
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var recordingInfo: some View {
        Form {
            Section("Recording") {
                LabeledContent("File") {
                    Text(model.fileName.isEmpty ? "No recording selected" : model.fileName)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if let duration = model.audioDuration {
                    LabeledContent("Duration", value: String(format: "%.1f seconds", duration))
                }
                if let time = model.processingTime {
                    LabeledContent("Processing", value: String(format: "%.2f seconds", time))
                }
            }

            Section("Speech Recognition") {
                LabeledContent("Model", value: "Voz")
                LabeledContent("Status", value: model.isReady ? "Ready" : model.modelIsDownloaded ? "Downloaded" : "Not downloaded")
                if !model.isReady {
                    Button(model.modelIsDownloaded ? "Load Model" : "Download Model") {
                        Task { await model.prepare() }
                    }
                    .disabled(model.isBusy)
                }
            }

            Section("Languages") {
                Link("Supported Languages", destination: URL(string: "https://desertant.com/models/voz/")!)
                Text("Voz supports 25 languages. Chinese is not supported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !model.modelIsDownloaded {
                Section {
                    Text("The model requires a download of about 337 MB. After downloading, it can transcribe offline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Refresh macOS accessibility values when the inspector’s data changes.
        .id(model.fileName)
        .id(model.isReady)
        .id(model.processingTime)
    }
}

struct TranscriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isRegularFile,
              let data = fileWrapper.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        fileWrapper()
    }

    func fileWrapper() -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
