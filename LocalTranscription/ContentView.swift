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
    @Environment(\.scenePhase) private var scenePhase
    // On iPhone the list is shown first; an import switches to the transcript so its progress shows.
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar
    @State private var isDropTargeted = false
    @State private var isConfirmingRevert = false
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
                            .help("Import audio recordings (⌘O), or drop them on the window")
                    }
                    if #available(macOS 26.0, iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(model.isEditing ? "Done" : "Edit", systemImage: model.isEditing ? "checkmark" : "pencil") {
                            if model.isEditing { model.endEditing() } else { model.beginEditing() }
                        }
                        .help(model.isEditing ? "Save your edits" : "Edit the transcript")
                        .disabled(!model.canEdit)
                        #if os(macOS)
                        Button("Copy Transcript", systemImage: "doc.on.doc") {
                            guard model.saveDraft() else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.displayTranscript, forType: .string)
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
        // Closing the window saves any edits in progress.
        .onDisappear { model.endEditing() }
        // Save edits when the app moves to the background or quits, not only when the window closes.
        .onChange(of: scenePhase) { if scenePhase != .active { model.autosaveDraft() } }
        #if os(macOS)
        .background(TranscriptWindowCloseGuard(model: model).allowsHitTesting(false))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.endEditing()
        }
        #endif
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importFiles(urls)
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return AudioFiles.partition(urls).audio.count > 0
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted { dropHighlight }
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
        .alert("Edits Not Saved", isPresented: Binding(
            get: { model.editSaveError != nil },
            set: { if !$0 { model.keepEditing() } }
        )) {
            Button("Discard Edits", role: .destructive) { model.discardDraft() }
            Button("Keep Editing", role: .cancel) { model.keepEditing() }
        } message: {
            Text((model.editSaveError ?? "") + "\n\nDiscarding keeps the transcript as it was last saved.")
        }
        .alert("Changed in Another Window", isPresented: Binding(
            get: { model.editConflict },
            set: { if !$0 { model.keepEditing() } }
        )) {
            Button("Keep My Version") { model.keepMyVersion() }
            Button("Use Other Version", role: .destructive) { model.useOtherVersion() }
            Button("Keep Editing", role: .cancel) { model.keepEditing() }
        } message: {
            Text("“\(model.fileName)” was edited in another window after you started editing here. Keep your version to replace it, or use the other version and discard your edits.")
        }
        #if os(macOS)
        .alert("Quit Without Saving?", isPresented: $model.isConfirmingQuit) {
            Button("Save Transcript…") { export(.text) }
            Button("Quit Anyway", role: .destructive) {
                model.discardUnsavedResult()
                NSApplication.shared.terminate(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript of “\(model.unsavedResultName ?? "")” couldn’t be saved to history and will be lost.")
        }
        #endif
        .alert("Language Not Supported", isPresented: Binding(
            get: { model.languageWarning != nil },
            set: { if !$0 { model.hideLanguageWarning() } }
        ), presenting: model.languageWarning) { warning in
            Button("Transcribe Anyway") { Task { await model.transcribeAnyway(warning) } }
            Button("Cancel", role: .cancel) { Task { await model.dismissLanguageWarning() } }
        } message: { warning in
            Text("This recording sounds like \(warning.language.name), which Voz can’t transcribe. Transcribing it anyway will likely produce incorrect text.")
        }
    }

    private func importFiles(_ urls: [URL]) {
        // On iPhone, show the transcript screen so the queue’s progress is visible.
        preferredColumn = .detail
        Task { await model.importFiles(urls) }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .padding(6)
            .overlay {
                Label("Drop audio to transcribe", systemImage: "waveform")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func export(_ format: TranscriptFormat) {
        // Render once here; rendering in body would re-format long subtitles on every progress update.
        guard model.saveDraft() else { return }
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
                    Text("Import or drop audio recordings to create transcripts on your device, or choose one from History.")
                } actions: {
                    Button("Import Audio…") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if model.isEditing {
                transcriptEditor
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Transcript")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        if showTimestamps && !model.cues.isEmpty {
                            timedTranscript
                        } else {
                            Text(model.transcript.isEmpty ? "No speech was recognized." : model.displayTranscript)
                                .font(transcriptFont)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(model.contentVersion)
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

    // Not inside the transcript’s ScrollView, and never given an .id that autosave would change,
    // so the cursor and undo history survive saving.
    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Editing Transcript")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            TextEditor(text: Binding(get: { model.draft ?? "" }, set: { model.updateDraft($0) }))
                .font(transcriptFont)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Transcript")
            Text("Edits save automatically. Subtitle timings are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity)
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
            return time + AttributedString(cue.labelledText.replacingOccurrences(of: "\n", with: " "))
        }
        let text = lines.dropFirst().reduce(lines.first ?? AttributedString()) { $0 + AttributedString("\n") + $1 }
        return Text(text)
            .font(transcriptFont)
            .lineSpacing(10)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(model.contentVersion)
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
                    if model.queuedCount > 0 {
                        Spacer(minLength: 8)
                        Text("\(model.queuedCount) more queued")
                        Button("Clear Queue") { model.clearQueue() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                } else {
                    Image(systemName: "lock.shield")
                        .accessibilityHidden(true)
                    Text("On-device transcription")
                    Spacer(minLength: 8)
                    if let duration = model.audioDuration, let time = model.processingTime {
                        Text("\(DisplayFormat.duration(duration)) audio · \(DisplayFormat.processingTime(time)) processing")
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
                    LabeledContent("Duration", value: DisplayFormat.duration(duration))
                }
                if !model.fileName.isEmpty {
                    LabeledContent("Language", value: languageDescription)
                }
                if model.speakerCount > 0 {
                    LabeledContent("Speakers", value: "\(model.speakerCount)")
                }
                if !model.shownVocabulary.isEmpty {
                    LabeledContent("Names and Terms", value: model.shownVocabulary.formatted(.list(type: .and)))
                }
                if let edited = model.editedDate {
                    LabeledContent("Edited", value: edited.formatted(date: .abbreviated, time: .shortened))
                    Button("Revert to Original…") { isConfirmingRevert = true }
                        .disabled(model.isLoadingSelection)
                }
                if let time = model.processingTime {
                    LabeledContent("Processing", value: DisplayFormat.processingTime(time))
                }
                Toggle("Show Timestamps", isOn: $showTimestamps)
                    .disabled(model.cues.isEmpty)
            }

            Section {
                TextField("Names and terms", text: $model.vocabularyText,
                          prompt: Text("Siobhan, Patek Philippe"), axis: .vertical)
                    .lineLimit(2...5)
                    .labelsHidden()
                    .accessibilityLabel("Names and terms for the next recordings")
            } header: {
                Text("Names and Terms")
            } footer: {
                Text(model.vocabulary.count > Vocabulary.suggestedLimit
                     ? "Long lists can make transcripts worse. Keep only names and terms these recordings contain."
                     : "Used for the recordings you import next. List people, places, and terms they mention, separated by commas or new lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Speaker Identification") {
                Toggle("Identify Speakers (Who)", isOn: $model.identifySpeakers)
                    .help("Label speakers in recordings imported next")
                Text("Best for conversations with up to four speakers. Applies to new imports. The first use downloads an additional model; later imports can run offline. Speaker numbers are specific to each recording, not people’s names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Languages") {
                DisclosureGroup("\(DisplayFormat.supportedLanguageNames().count) Supported Languages") {
                    Text(DisplayFormat.supportedLanguageNames().formatted(.list(type: .and)))
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Text("Chinese, Japanese, Korean, and other languages aren’t supported. The app warns before transcribing them.")
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
        .id(InspectorIdentity(content: model.contentVersion, isReady: model.isReady))
        .confirmationDialog("Revert to the original transcript?", isPresented: $isConfirmingRevert) {
            Button("Revert", role: .destructive) { Task { await model.revertToOriginal() } }
        } message: {
            Text("Your edits to this transcript will be replaced by the text as it was transcribed.")
        }
    }
}

#if os(macOS)
/// Intercepts closing before SwiftUI tears down the view that owns an unsaved draft.
struct TranscriptWindowCloseGuard: NSViewRepresentable {
    let model: TranscriptionModel

    func makeNSView(context: Context) -> GuardView { GuardView(model: model) }
    func updateNSView(_ view: GuardView, context: Context) { view.installDelegate() }
    static func dismantleNSView(_ view: GuardView, coordinator: ()) { view.restoreDelegate() }

    final class GuardView: NSView {
        let model: TranscriptionModel
        private var closeDelegate: TranscriptWindowDelegate?
        private weak var guardedWindow: NSWindow?

        init(model: TranscriptionModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installDelegate()
        }

        func installDelegate() {
            guard guardedWindow !== window || window?.delegate !== closeDelegate else { return }
            restoreDelegate()
            guard let window else { return }
            let delegate = TranscriptWindowDelegate(model: model, originalDelegate: window.delegate)
            closeDelegate = delegate
            guardedWindow = window
            window.delegate = delegate
        }

        func restoreDelegate() {
            if let guardedWindow, guardedWindow.delegate === closeDelegate {
                guardedWindow.delegate = closeDelegate?.originalDelegate
            }
            guardedWindow = nil
            closeDelegate = nil
        }
    }
}

/// Forwards the existing SwiftUI window delegate’s behavior while guarding draft saves.
final class TranscriptWindowDelegate: NSObject, NSWindowDelegate {
    let model: TranscriptionModel
    weak var originalDelegate: (any NSWindowDelegate)?

    init(model: TranscriptionModel, originalDelegate: (any NSWindowDelegate)?) {
        self.model = model
        self.originalDelegate = originalDelegate
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.endEditing() else { return false }
        return originalDelegate?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }
}
#endif

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

/// Rebuilds Recording Info, refreshing macOS accessibility values, when what it shows changes.
private struct InspectorIdentity: Hashable {
    let content: Int
    let isReady: Bool
}
