# Local Transcription

A local transcription app for Apple Silicon Macs running macOS 15+, using Desert Ant Labs’ Voz speech recognizer. Import an audio recording, copy the transcript, or save it as a UTF-8 text file. The shared SwiftUI project also supports iOS 18+. Building from source requires Xcode 26+ and Swift 6.2+.

## Run

Open `dist/LocalTranscription.app` to launch the standalone Mac app. It automatically loads the model if it is already cached. Use **Import Audio** (⌘O), **Copy Transcript**, and **Save Transcript** (⌘S). **Export Subtitles** saves timed SubRip (`.srt`) or WebVTT (`.vtt`) captions built from Voz’s word timings; cues break at sentence ends, pauses longer than one second, six seconds, or two 42-character lines. Turn on **Show Timestamps** in Recording Info to see each cue’s start time beside the transcript. The status bar shows percentage progress while the model downloads and while a recording is transcribed; preparing the model for the Neural Engine has no measurable progress and shows a spinner. Voz reports full transcription progress before decoding finishes (after about a quarter of the processing time on an 11-minute recording), so the bar then gives way to a spinner instead of showing 100% while work continues.

Drop one or more audio files on the window, or select several in **Import Audio**, to transcribe them one after another; each becomes its own History entry. Files that aren’t audio are named in an error and skipped. Import stays available while a recording is transcribed, adding to the queue, and the status bar shows how many files wait, with **Clear Queue** to drop them. A failed file is reported by name and the rest continue. The language warning pauses the queue until you choose; either choice continues with the next file. Opening files from Finder with **Open With** is not yet supported.

Every successful transcription is saved to **History**, the sidebar on the left, newest first; select an entry to show its transcript, timestamps, and exports again. Importing a new recording no longer replaces earlier work. Delete an entry with its context menu, the Delete key, or a swipe on iOS, or remove everything with **More → Clear History…**, which asks for confirmation. Failed imports and recordings declined at the language warning are not saved.

The macOS interface uses a unified system toolbar with grouped actions, a History sidebar, a standard Recording Info inspector, a compact status bar, and a transcript column that adapts to the window width. The inspector button and View menu show or hide recording details, model readiness, and language support. Standard SwiftUI components adopt macOS 27’s appearance and the Mac’s display settings; macOS 15 remains supported. Design follows Apple’s [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

Use **View → Increase Transcript Text Size**, **Decrease Transcript Text Size**, or **Actual Transcript Text Size** to adjust transcript content from 75% to 300%; the choice is saved. The 200% layout, keyboard navigation, Reduce Transparency, transcript heading, and progress label were checked on this Mac before the History sidebar was added; the sidebar narrows the transcript column, so the 200% layout and keyboard navigation need rechecking. The minimum window width is now 980 points to leave room for all three columns. System preferred reading size does not resize this app, and spoken VoiceOver remains unverified. See the [accessibility report](verification/accessibility-check-results.md) for results and limits.

The standalone Release app was launched on this Mac and verified through its native file dialogs: it imported the spoken test recording, displayed the correct transcript, and exported matching UTF-8 text. The macOS 27 interface was checked with its inspector visible and hidden, and keyboard import/export produced `verification/voz-macos27-transcript.txt`.

To rebuild the local Mac app, run `zsh Scripts/build-mac.sh`. This produces an optimized Apple Silicon build with an ad hoc local signature. The local build runs without App Sandbox so it can reuse the model already downloaded in your user cache. It is not notarized for distribution to other Macs.

The blue waveform-and-transcript app icon is included in `LocalTranscription/Assets.xcassets/AppIcon.appiconset`, following Apple’s [app icon asset catalog configuration](https://developer.apple.com/documentation/xcode/configuring-your-app-icon). The catalog contains all ten Mac sizes and an opaque 1024-pixel iOS image. To change the artwork, edit `Scripts/generate-app-icon.swift`, run `swift Scripts/generate-app-icon.swift` from the project root, and rebuild. If you previously copied the app into Applications, replace that copy with the rebuilt app and reopen it.

To run from Xcode:

1. Open `LocalTranscription.xcodeproj` in Xcode and let Swift Package Manager resolve the SDK.
2. Choose the `LocalTranscription` scheme and My Mac or a physical iPhone/iPad. Set your signing team and a unique bundle identifier to run on an iOS device.
3. Select **Download Model** or **Load Model** to prepare Voz ahead of time, or **Import Audio** to prepare it and transcribe a recording. Cached models load automatically at launch. Copy the selectable transcript or use **Save Transcript**.

The first use downloads approximately 337 MB from Hugging Face; the first Neural Engine preparation typically takes 10–30 seconds after downloading. Later requests reuse one recognizer, and the SDK caches model files across launches. Cached models run offline. Use a physical Apple device with a Neural Engine to verify inference.

## App updates and Homebrew

On macOS, choose **LocalTranscription → Check for Updates…**. The app checks the [official GitHub releases](https://github.com/Austin-Almighty/MacLocalAudioTranscription/releases) only when requested. A newer published release offers **Download Update**, which opens its Mac ZIP in your default browser. Quit the app, open the ZIP, and replace the app in Applications. Homebrew users should upgrade through Homebrew instead. No audio or transcript is sent during update checks; GitHub receives a normal network request.

Drafts and prereleases are excluded, and the app requires an uploaded `LocalTranscription-macOS-arm64.zip` asset from this repository. No published release, an unavailable download, offline access, and server failures report a message without changing the installed app. iOS updates remain outside this Mac release flow. The implementation follows [GitHub’s latest-release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release).

After the first official release and its matching cask have been published, install through this repository’s [Homebrew tap](https://docs.brew.sh/Taps):

```sh
brew tap Austin-Almighty/MacLocalAudioTranscription https://github.com/Austin-Almighty/MacLocalAudioTranscription.git
brew install --cask local-transcription
```

For subsequent releases:

```sh
brew update
brew upgrade --cask local-transcription
```

This is a personal tap; it does not require a listing in Homebrew’s central cask repository. The cask supports Apple Silicon and macOS 15 or newer. If you already installed the app manually, move that copy out of Applications before installing the cask.

To prepare an official release:

1. Set `MARKETING_VERSION` in both app build configurations to the new numeric version, such as `1.1.0`, and increment `CURRENT_PROJECT_VERSION`. Use one to three numeric version components.
2. Run the regression suite and `zsh Scripts/build-mac.sh`. For public distribution, sign with Developer ID, notarize, and staple the finished app before packaging. The local build script provides only an ad hoc signature.
3. Run `zsh Scripts/package-release.sh`. It refuses apps that Gatekeeper rejects or that lack a stapled notarization ticket, including the ad hoc build from `Scripts/build-mac.sh`. It packages the finished app into `dist/LocalTranscription-macOS-arm64.zip` and writes `Casks/local-transcription.rb` with the archive’s SHA-256, following the [Homebrew cask format](https://docs.brew.sh/Cask-Cookbook). Upload that exact ZIP; do not rebuild or repackage it afterward.
4. Commit the source changes, create a GitHub release tagged `v` followed by that exact version, and upload the ZIP. Keep it a draft while uploading, then publish it as the latest stable release. Publish the generated cask on `main` after the release download is available, so Homebrew’s version and checksum stay in sync.

Preparing a ZIP or cask does not publish an official release. The update check begins offering it only after the stable release and its download are available on GitHub.

## SDK integration

The Xcode project uses Swift Package Manager with `desert-ant-core` starting at **4.0.0**, up to the next major version, and links the `Voz`, `Ear`, and `DesertAnt` products. The equivalent package declarations are:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.0.0")

// Target dependencies:
.product(name: "Voz", package: "desert-ant-core")
.product(name: "Ear", package: "desert-ant-core")
.product(name: "DesertAnt", package: "desert-ant-core")
```

The API and version were checked against the [v4.0.0 README](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.0.0/README.md), [Voz documentation](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.0.0/docs/models/voz.md), and release source:

```swift
import DesertAnt
import Voz

DesertAnt.fasterNeuralEngineCompile = false
let voz = try await Voz()
let result = try await voz.transcribe(url)
print(result.text)
```

`DesertAnt` is linked explicitly to disable the private Core ML compilation optimization documented in the README. Transcription uses the SDK’s default Core ML compute configuration (`.cpuAndNeuralEngine`). Imported files retain security-scoped access for the whole operation; the macOS sandbox permits user-selected read/write files and outgoing model downloads. No microphone permission is needed for audio file import.

## Limits and data use

- Voz supports 25 [languages](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.0.0/Sources/Voz/Voz.swift) and produces incorrect text, without an error, for others such as Chinese. Before transcribing, the app identifies the spoken language on device with the SDK’s Ear model. When Ear is confident the language is unsupported, the app asks before loading Voz and offers **Transcribe Anyway** or **Cancel**; Cancel keeps the previous transcript. Uncertain detections, including Norwegian, Swedish, and Danish, which Ear confuses, never block transcription. Recording Info shows the detected language. For long recordings, Ear listens to six evenly spaced 30-second segments rather than decoding the whole file.
- Ear’s model (about 5 MB) is downloaded from Hugging Face in the background after Voz is ready. Until it is on disk, or if identification fails, recordings are transcribed without a language check and failures are logged. Optimized builds identify a recording in about 0.1 seconds after Ear’s first load; unoptimized Debug builds can take several seconds.
- Audio and transcripts stay on the device. History keeps each transcript, its timed cues, the recording’s file name, duration, and detected language as JSON in `~/Library/Application Support/LocalTranscription/History/` (inside the app’s container when sandboxed) until you delete it. Audio and the recording’s original location are not kept. Unreadable or newer-format entries are skipped and logged, never deleted automatically; Clear History removes every file in that folder. Recordings in which no speech was recognized are not saved. The SDK independently sends monthly model-license requests for each model it uses (Voz and Ear) containing installation, app, model, and platform metadata, with no audio or transcript, as described in its [README](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.0.0/README.md#model-licenses).
- Review the vendor’s [source-available license](https://license.desertant.com/1.0) before distribution.
- This starter imports recordings. Live microphone capture is outside its scope.

## Verify

In Xcode, use **Product → Test**. The [test cases and manual UI checklist](TEST_CASES.md) describe the coverage and expected behavior. The original suite contains 13 automated tests covering 24 cases: file validation, initial state, seven audio formats, Unicode file names, result retention after errors, recovery from corrupt audio, repeated model preparation, and UTF-8 transcript export/read validation.

All 24 cases passed on this Apple M4 Pro in about 6.6 seconds. The integration suite uses the real cached Voz model and skips explicitly when the model is not installed. It is compiled only for Apple Silicon macOS and never downloads weights. The other tests do not require a prepared model. The speech fixtures are bundled in the test target and do not require FFmpeg at test time.

Verified with Xcode on this Mac: package resolution at Voz 4.0.0, the macOS Apple Silicon build and regression suite, and the unsigned iOS device build passed. Debug builds use the active architecture so the app and SwiftPM dependencies agree. `Package.resolved` records the resolved SDK and dependency revisions. Swift syntax, project references, the shared scheme, and entitlements also passed validation.

The installed CoreSimulator reports a version mismatch, so iOS simulator tests were not run.

```sh
xcodebuild -project LocalTranscription.xcodeproj -scheme LocalTranscription \
  -destination 'platform=macOS,arch=arm64' test

xcodebuild -project LocalTranscription.xcodeproj -scheme LocalTranscription \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For inference verification, import a short English recording on a physical device, then disable networking and transcribe another recording with the cached model. Confirm the transcript, retry after an unreadable file, and check that the UI stays responsive during preparation and transcription.

The Mac update suite adds six tests covering numeric version ordering, invalid versions, unpublished releases, untrusted download links, malformed or missing assets, and HTTP failures. These tests pass independently of the model and network. Live release downloads require a published release and remain unverified.

The subtitle suite adds ten tests covering cue grouping at sentence ends, pauses, and length limits; two-line wrapping; minimum cue duration without overlap; exact SRT and WebVTT output, including timestamps past one hour; recordings with no speech; and export file types. Two more tests check that late progress updates are ignored. Progress bars and subtitle export from a real recording have not yet been checked with the model loaded.

## Verified model inference on this Mac

Voz v0.4.0 was downloaded and passed the SDK’s integrity checks on an Apple M4 Pro. A synthesized 5.79-second English recording was correctly transcribed twice in 0.107 and 0.092 seconds, approximately 54× and 63× real time. First model loading took 8.05 seconds; the subsequent traced process loaded the cached model in 0.27 seconds. These are short synthetic-fixture measurements, not a general accuracy or performance benchmark.

The model is cached at `~/Library/Caches/desert-ant-models/desert-ant-labs/voz/v0.4.0`. A signed sandboxed app can have a different cache directory and may download its own copy.

The [inference report](verification/voz-inference.json) contains timings and Core ML compute-plan preferences. The [runtime hardware events](verification/voz-ane-events.xml), exported from an Instruments Core AI recording, show two frontend (`mel`) and two encoder predictions executing on the Neural Engine. SDK 4.0.0 deliberately runs the small decoder on the CPU. The full Instruments recording is in `build/verification/voz-core-ai.trace`.

To repeat the checks with the existing macOS Debug SDK objects:

```sh
mkdir -p build/verification
xcodebuild build -project LocalTranscription.xcodeproj -scheme LocalTranscription \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=NO
say -v Samantha -r 150 -o build/verification/voz-fixture.aiff \
  'This is a local speech recognition test. The quick brown fox jumps over the lazy dog.'
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos15.0 \
  -module-cache-path build/verification/ModuleCache -I build/DerivedData/Build/Products/Debug \
  Scripts/verify-voz.swift build/DerivedData/Build/Products/Debug/*.o \
  -o build/verification/verify-voz
build/verification/verify-voz build/verification/voz-fixture.aiff verification/voz-inference.json
```

The verification tool checks the spoken content, nonempty word timestamps, timestamp bounds, model integrity, and encoder Neural Engine assignments. It does not record runtime hardware events itself. iOS device inference remains untested.

Offline inference, an empty-cache download failure, recovery by downloading into an isolated cache, and long noisy Spanish recordings were checked on this Mac. Outbound networking was denied only to the offline test process, with a failing network probe confirming the restriction. A 20-minute recording completed offline in 15.48 seconds; the Release app also completed a two-hour recording in 15.34 seconds. These are synthetic repeated-speech checks, not accuracy benchmarks. The [check report](verification/manual-check-results.md) records the UI results, remaining accessibility checks, evidence, and reproduction commands. The UI checks also found and fixed stale accessibility values after model loading and switching recordings.
