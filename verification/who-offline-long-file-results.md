# Who offline first use and long recordings — November 4, 2026

These command-line checks cover failure scenarios 9 and 10 in [FAILURE_SCENARIOS.md](../FAILURE_SCENARIOS.md). They ran at commit `6477156` on an Apple M4 Pro with 24 GB of memory and macOS 27.0.1 (26A434), with Desert Ant SDK 4.0.0, Who v0.3.1 (float16), Voz v0.4.0 and Ear v0.2.0. A separate reviewer checked each result against its logs.

The offline harness drove the app’s import and History code directly. The long-file harness called the Voz and Who SDKs and used the app’s code to assign speaker labels and build cues. Both harnesses compiled the app’s non-UI Swift sources. The offline imports and timed long-file runs used `Scripts/offline.sb` and a `CFFIXED_USER_HOME` under `build/scenario-9-10/` to isolate caches, History and preferences. The original workspace keeps the sources, scripts, logs and JSON reports in that ignored folder.

## Scenario 9: first use of Who while offline

The isolated home held Voz and Ear. Who was uncached. A `curl` request to Hugging Face failed inside the sandbox (“Could not resolve host”) and succeeded outside it. A URLSession probe in the harness failed with `NSPOSIXErrorDomain` code 1. The harness then called `TranscriptionModel.importFiles` on the 23-second two-voice conversation with Identify Speakers on.

| Measure | Run 1 (cold) | Run 2 |
| --- | --- | --- |
| Import time | 13.1 s | 4.6 s |
| Time from “Transcribing on device…” to finished | 0.3 s | — |
| Peak resident memory | 414 MiB | — |
| History entries afterward | 1 | 2 |

In both runs the app model returned to idle, selected the new History entry and saved all nine cues without speaker labels.

> “conversation.wav” was transcribed, but its speakers couldn’t be identified. The operation couldn’t be completed. Operation not permitted

The path is `TranscriptionModel.subtitleCues` (`LocalTranscription/TranscriptionModel.swift:267-280`). It calls `WhoSpeakerIdentifier.identify` (`LocalTranscription/SpeakerIdentification.swift:10-16`), catches the error, logs it, adds the message and returns unlabelled cues.

### Offline test limits

- The native Who alert remained unverified at this baseline. The [earlier UI-09 check](manual-check-results.md) exercised a Voz preparation error.
- Connections failed immediately under the sandbox’s network denial. Wait times on networks that silently drop requests remain unmeasured.
- The baseline error left the required one-time Who download unexplained.
- Both failures left an empty `who/v0.3.1` folder in the isolated cache.

## Scenario 10: Who on long recordings

Who decodes the whole file into memory as mono 16 kHz Float samples (SDK `Who+Audio.swift:13-14`) and normalises across the whole recording. The SDK runs the model in 300-second parts (`Model.swift:150`, `Pieces.swift:18-21`). In the app, Who runs after Voz finishes (`TranscriptionModel.swift:255`, then `:273`).

The recordings were `spanish-noisy-20min.wav` and `spanish-noisy-2hr.wav` from `build/manual-checks/`. Each file repeats one synthetic voice. The timed runs used cached models and a warm Neural Engine compile cache. Each configuration ran three times.

| File | Who alone | Who peak memory | Voz + Who + speaker labels + cues | Full-flow peak memory |
| --- | --- | --- | --- | --- |
| 20 minutes | 1.5 s | 285–289 MiB | 4.4–4.6 s | 331–345 MiB |
| 2 hours | 8.9 s | 664–668 MiB | 24.6 s | 731–747 MiB |

Memory is the peak memory footprint reported by `/usr/bin/time -l`. On the 2-hour file, Voz took 15.2 s, which matches the 15.34 s the Release app took in the earlier check. Voz alone peaked at 277–313 MiB. Speaker labels and cues took under 0.05 s, and all 24,964 words got a label.

Across the two fixtures, Who’s peak footprint rose by about 225 MiB per additional hour of audio. The decoded samples account for most of that increase at about 220 MiB per hour. The SDK also retains per-piece speaker data and can allocate recording-length masks for speaker matching (`Model.swift:158-207`). The measured files ran within the memory available on this Mac. The results describe this setup and leave a general length warning threshold undetermined.

In one separate run with an empty Neural Engine compile cache, Who load and diarization took 164 s on the 23-second file. The process peaked at about 1.45 GiB of resident memory. Voz was also cold, and the earlier harness log lacks the sandbox header recorded for the timed long-file runs.

### Benchmark limits

- The machine was busy (load average 3.6–6.7, including a game client), so wall times were measured under load. Inference runs mostly on the Neural Engine.
- Measurements cover the command-line process. They exclude the SwiftUI window and Ear’s language check.
- Longer files, multi-speaker recordings, lower-memory Macs and runs under memory pressure remain unmeasured.

## Workspace-specific reproduction notes

These commands document the original workspace at baseline commit `6477156`. They depend on ignored harness sources, launch scripts, fixtures and cached models under `build/`. The launch scripts contain absolute paths to that workspace. Both harnesses use SDK objects built with macOS SDK 27.2.

```sh
# Scenario 9
xcodebuild build -project LocalTranscription.xcodeproj -scheme LocalTranscription -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/scenario-9-10/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS=
```

The offline harness links those objects with the app’s non-UI sources. The long-file harness compiles `long-file/long-who.swift` to `long-file/long-who` with `-O` and the Release objects under `build/scenario-9-10/long-file/DerivedData-Release/Build/Products/Release`.

```sh
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos15.0 \
  -module-cache-path build/scenario-9-10/ModuleCache \
  -I build/scenario-9-10/DerivedData/Build/Products/Debug \
  -I build/SourcePackages/checkouts/swift-numerics/Sources/_NumericsShims/include \
  build/scenario-9-10/offline-who/check-offline-who.swift \
  $(ls LocalTranscription/*.swift | grep -v -e ContentView -e HistorySidebar -e LocalTranscriptionApp) \
  build/scenario-9-10/DerivedData/Build/Products/Debug/*.o \
  -o build/scenario-9-10/offline-who/check-offline-who
```

```sh
build/scenario-9-10/offline-who/run.sh
build/scenario-9-10/long-file/run.sh who  build/manual-checks/spanish-noisy-2hr.wav who-2hr-1
build/scenario-9-10/long-file/run.sh full build/manual-checks/spanish-noisy-2hr.wav full-2hr-1
```
