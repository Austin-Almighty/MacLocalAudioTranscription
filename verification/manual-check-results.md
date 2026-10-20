# Offline and app checks — October 16, 2026

Checked on Apple M4 Pro, macOS 27.0.1, with SDK 4.0.0 and Voz weights v0.4.0.

The working model cache and the user’s app session were preserved. UI checks used a separately identified copy in `build/manual-checks/LocalTranscriptionChecks.app`. Offline checks used a process sandbox denying outbound networking, rather than disconnecting the Mac. A URLSession request to Hugging Face failed inside each offline process before inference was attempted.

## Results

| Check | Result and evidence |
| --- | --- |
| Cached offline inference (UI-10) | **Passed at the production model layer.** Loaded Voz and transcribed the 5.79-second English fixture in 0.131 seconds with outbound networking denied. Text matched the expected sentence. See [offline-cached.json](offline-cached.json). |
| Empty cache while offline (UI-09) | **Passed.** Used `CFFIXED_USER_HOME` to isolate Foundation’s cache. Preparation reported a network error, left `isBusy = false` and `isReady = false`, and created no transcript. The native app also displayed the error and restored its enabled controls. See [offline-cold.json](offline-cold.json). |
| Download recovery (UI-09) | **Passed for initial connection failure.** A new online verifier using that same isolated cache downloaded and loaded the model, then transcribed Spanish successfully. The still-running offline UI instance subsequently loaded that now-complete cache when its Download Model action was retried. See [online-retry.json](online-retry.json). This does not test interruption halfway through transferring a weight file. |
| Long, noisy Spanish offline (UI-12) | **Passed.** Transcribed 1,200 seconds of repeated Spanish speech with added pink noise in 15.4755 seconds. Required Spanish phrases appeared in the result. A second import attempted while the production model was busy did not replace the first recording. See [offline-long-spanish.json](offline-long-spanish.json). |
| Cached launch (UI-01) | **Passed.** Automatically loaded the model, displayed Ready and No Recording, and enabled Import. |
| Native import and metadata (UI-02) | **Passed.** ⌘O opened the native panel. Imported AIFF speech, obtained the expected transcript, and checked filename, duration, and processing time. |
| Cancel import (UI-03) | **Passed.** Cancelled after a successful transcription; the transcript and enabled controls remained, with no error alert. |
| Clipboard (UI-04) | **Passed.** Clicked Copy Transcript, created a new TextEdit document, and pasted the exact English transcript. Evidence remains in `build/manual-checks/clipboard-check.rtf`. |
| Native export (UI-05) | **Passed.** ⌘S opened the export panel with the audio basename “speech”. Exported plain text and compared the bytes against the recognized text encoded as UTF-8. They matched exactly. See [manual-ui-transcript.txt](manual-ui-transcript.txt). |
| Cancel export (UI-06) | **Passed.** Cancelled a separate export; the existing transcript remained and no error alert appeared. |
| Inspector and window sizes (UI-07) | **Passed.** Hid the inspector with its toolbar control, restored it using View → Show Inspector, and zoomed/restored the window. Transcript and controls remained readable without overlap. |
| Busy state and second import (UI-08) | **Passed.** The Release app showed Transcribing on device and disabled Import during a two-hour noisy Spanish recording. It completed with one result and reenabled Import; metadata showed 7,200 seconds and 15.34 seconds of processing. The separate offline model check asserted that a concurrent second import was ignored. |
| Appearance and accessibility (UI-11) | **Partially passed.** Inspected light and dark appearances, shortcut import/export, accessible action names, and dynamic transcript/metadata values. Light appearance was forced only in the disposable app copy using `NSRequiresAquaSystemAppearance`; system settings and the distributed app plist were unchanged. A [subsequent accessibility check](accessibility-check-results.md) exercised keyboard navigation, Reduce Transparency, and enlarged transcript text, and improved heading/progress semantics. Spoken VoiceOver remains unverified. |
| Regression suite | **Passed after the final fix.** All 13 tests, covering 24 parameterized cases in three suites, passed in 6.876 seconds. Log: `/tmp/local-transcription-offline-regression.log`. The matching `.xcresult` is under `build/DerivedData/Logs/Test/`. |
| Release build and signature | **Passed.** Rebuilt `dist/LocalTranscription.app` and verified its ad hoc signature. |

The long recordings repeat a short synthetic utterance. Their timings demonstrate completion and state handling on this machine, not accuracy on natural two-hour meetings, varied speakers, or severe background noise. The 20-minute offline verifier used Debug SDK objects; the two-hour GUI check used the optimized Release app, so their speeds are not directly comparable.

## Fix discovered during verification

The visual inspector was correct, but macOS’s accessibility tree retained old model status and filenames after data changed. The transcript text could also remain stale when a second recording replaced the first.

`ContentView.swift` now recreates the native inspector when the filename, model readiness, or processing time changes, and recreates the transcript Text when its contents change. The final build’s accessibility tree correctly reported `spanish-noisy-2hr.wav`, `7200.0 seconds`, `Voz Ready`, and the repeated Spanish transcript. A final check found 1,158 occurrences of the Spanish reference phrase and no stale English fixture text. The fix uses native controls and adds no dependencies.

## Reproduce the process checks

From the project root, first build the Debug SDK objects using the test command in [TEST_CASES.md](../TEST_CASES.md), then compile the verifier without optimization so its preconditions remain enabled:

```sh
mkdir -p build/manual-checks build/verification/ModuleCache
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos15.0 \
  -module-cache-path build/verification/ModuleCache \
  -I build/DerivedData/Build/Products/Debug \
  Scripts/verify-offline.swift LocalTranscription/TranscriptionModel.swift \
  build/DerivedData/Build/Products/Debug/*.o \
  -o build/manual-checks/check-offline

# Requires the working model to be cached already.
sandbox-exec -f Scripts/offline.sb build/manual-checks/check-offline \
  cached LocalTranscriptionTests/Fixtures/speech.aiff verification/offline-cached.json

# Use a new, empty test home, never the working user cache.
CFFIXED_USER_HOME="$PWD/build/manual-checks/offline-repro-home" \
  sandbox-exec -f Scripts/offline.sb build/manual-checks/check-offline \
  cold LocalTranscriptionTests/Fixtures/speech.aiff verification/offline-cold.json

# Optional recovery check: downloads about 337 MB into that same test home.
CFFIXED_USER_HOME="$PWD/build/manual-checks/offline-repro-home" \
  build/manual-checks/check-offline online \
  LocalTranscriptionTests/Fixtures/speech.aiff verification/online-retry.json
```

The cold and online modes deliberately reject an already complete cache. Choose another new test-home path when repeating the pair. The helper verifies the app’s actual `TranscriptionModel`, rather than a substitute recognizer. Compile and execute outside an enclosing sandbox that prevents Swift macro plugins, Core ML services, or nested `sandbox-exec` from starting; no system-wide network changes are required.

To recreate the long Spanish fixture used in the offline check:

```sh
say -v Mónica -r 155 -o build/manual-checks/spanish.aiff \
  'Esta es una prueba de transcripción local. El reconocimiento de voz funciona en este equipo sin enviar el audio a un servidor.'
ffmpeg -nostdin -y -loglevel error \
  -stream_loop -1 -i build/manual-checks/spanish.aiff \
  -f lavfi -i 'anoisesrc=color=pink:amplitude=0.02:r=16000' \
  -filter_complex '[0:a]aresample=16000[a];[a][1:a]amix=inputs=2:duration=first:normalize=0[out]' \
  -map '[out]' -t 1200 -c:a pcm_s16le build/manual-checks/spanish-noisy-20min.wav
sandbox-exec -f Scripts/offline.sb build/manual-checks/check-offline \
  long build/manual-checks/spanish-noisy-20min.wav verification/offline-long-spanish.json
```

These generated files and the isolated cache remain under the ignored `build/manual-checks/` directory. No iOS device inference or simulator verification was performed in this run; the existing simulator version mismatch remains unresolved.
