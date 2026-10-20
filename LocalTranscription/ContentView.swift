import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @State private var model = TranscriptionModel()
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportFormat = TranscriptFormat.text
    @State private var exportDocument = TranscriptDocument(text: "")
    @AppStorage("showTimestamps") private var showTimestamps = false
    // On iPhone the list is shown first; an import switches to the transcript so its progress shows.
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar
    #if os(macOS)
    @State private var showingInspector = true
    @AppStorage("transcriptTextScale") private var transcriptTextScale = 1.0
    #else
    @State private var showingInspector = false
    #endif

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            HistorySidebar(model: model, isImporting: $isImporting)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
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
                        Button("Save Transcript…", systemImage: "square.and.arrow.down") { export(.text) }
                            .keyboardShortcut("s")
                            .help("Save the transcript as text (⌘S)")
                            .disabled(model.transcript.isEmpty)
                        Menu("Export Subtitles", systemImage: "captions.bubble") {
                            Button("SubRip (.srt)…") { export(.subRip) }
                            Button("WebVTT (.vtt)…") { export(.webVTT) }
                        }
                        .help("Export timed subtitles")
                        .disabled(model.cues.isEmpty)
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
        // Wide enough for the history list, the transcript, and Recording Info side by side.
        .frame(minWidth: 980, minHeight: 480)
        #else
        .frame(minWidth: 300, minHeight: 420)
        #endif
        // Separate tasks, so loading the model doesn’t wait for history to be read.
        .task { await model.history.load() }
        .task {
            if model.modelIsDownloaded { await model.prepare() }
        }
        .onChange(of: model.history.entries) { model.reconcileWithHistory() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                preferredColumn = .detail
                Task { await model.transcribe(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: exportDocument,
                      contentType: exportFormat.contentType,
                      defaultFilename: (model.fileName as NSString).deletingPathExtension + "." + exportFormat.fileExtension) { result in
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
        .alert("Language Not Supported", isPresented: Binding(
            get: { model.languageWarning != nil },
            set: { if !$0 { model.dismissLanguageWarning() } }
        ), presenting: model.languageWarning) { warning in
            Button("Transcribe Anyway") { Task { await model.transcribeAnyway(warning) } }
            Button("Cancel", role: .cancel) { model.dismissLanguageWarning() }
        } message: { warning in
            Text("This recording sounds like \(warning.language.name), which Voz can’t transcribe. Transcribing it anyway will likely produce incorrect text.")
        }
    }

    private func export(_ format: TranscriptFormat) {
        // Render once here; rendering in body would re-format long subtitles on every progress update.
        exportFormat = format
        exportDocument = TranscriptDocument(text: format.render(transcript: model.transcript, cues: model.cues))
        isExporting = true
    }

    private var recordingContent: some View {
        Group {
            if model.fileName.isEmpty {
                ContentUnavailableView {
                    Label("No Recording", systemImage: "waveform")
                } description: {
                    Text("Import an audio recording to create a transcript on your device, or choose one from History.")
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
                        if showTimestamps && !model.cues.isEmpty {
                            timedTranscript
                        } else {
                            Text(model.transcript.isEmpty ? "No speech was recognized." : model.transcript)
                                .font(transcriptFont)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(model.transcript)
                        }
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

    private var languageDescription: String {
        guard let language = model.detectedLanguage else { return "Not identified" }
        return language.isReliable ? language.name : "\(language.name) (uncertain)"
    }

    private var transcriptFont: Font {
        #if os(macOS)
        .system(size: NSFont.preferredFont(forTextStyle: .title3, options: [:]).pointSize * transcriptTextScale)
        #else
        .title3
        #endif
    }

    private var timedTranscript: some View {
        let pattern: Duration.TimeFormatStyle.Pattern = (model.audioDuration ?? 0) >= 3600 ? .hourMinuteSecond : .minuteSecond
        // One Text, so a selection can span several cues and copies with their timestamps.
        let lines = model.cues.map { cue in
            var time = AttributedString(Duration.seconds(cue.start).formatted(.time(pattern: pattern)) + "  ")
            time.font = .callout.monospacedDigit()
            time.foregroundColor = .secondary
            return time + AttributedString(cue.text.replacingOccurrences(of: "\n", with: " "))
        }
        let text = lines.dropFirst().reduce(lines.first ?? AttributedString()) { $0 + AttributedString("\n") + $1 }
        return Text(text)
            .font(transcriptFont)
            .lineSpacing(10)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(model.transcript)
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let status = model.status {
                    if let progress = model.progress {
                        ProgressView(value: progress)
                            .frame(width: 120)
                            .accessibilityLabel(status)
                        Text(status).accessibilityAddTraits(.updatesFrequently)
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(status)
                        Text(status).accessibilityAddTraits(.updatesFrequently)
                    }
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
                if !model.fileName.isEmpty {
                    LabeledContent("Language", value: languageDescription)
                }
                if let time = model.processingTime {
                    LabeledContent("Processing", value: String(format: "%.2f seconds", time))
                }
                Toggle("Show Timestamps", isOn: $showTimestamps)
                    .disabled(model.cues.isEmpty)
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
    static var writableContentTypes: [UTType] { TranscriptFormat.allCases.map(\.contentType) }
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
