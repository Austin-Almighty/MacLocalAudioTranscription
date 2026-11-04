# Who offline first use and long recordings — November 4, 2026

These checks cover failure scenarios 9 and 10 in [FAILURE_SCENARIOS.md](../FAILURE_SCENARIOS.md). Neither found a bug, so the app code is unchanged. Both ran on an Apple M4 Pro with 24 GB of memory, macOS 27.0.1 (26A434), at commit `6477156`, with Desert Ant SDK 4.0.0, Who v0.3.1 (float16), Voz v0.4.0 and Ear v0.2.0. A separate reviewer re-checked each result against its logs and confirmed it, with the caveats listed below.

Both checks used command-line tools that compile the app’s own non-UI sources (everything in `LocalTranscription/` except `ContentView`, `HistorySidebar` and `LocalTranscriptionApp`), so the transcription, speaker and History code is the app’s real code. Every run used `Scripts/offline.sb` and a `CFFIXED_USER_HOME` under `build/scenario-9-10/`, so the normal app’s caches, History and preferences were not touched. Tool sources, scripts, logs and JSON reports are in the ignored `build/scenario-9-10/` folder.

## Scenario 9: first use of Who while offline

**Result: as expected.** The transcript is kept without labels, an error names the recording, and nothing hangs.

The isolated home held Voz and Ear but no Who. Outbound networking was denied, which was confirmed three ways: `curl` to Hugging Face failed inside the sandbox (“Could not resolve host”) and succeeded outside it, and a URLSession probe in the tool failed with `NSPOSIXErrorDomain` code 1. The tool then called `TranscriptionModel.importFiles` on the 23-second two-voice conversation with Identify Speakers on.

| Measure | Run 1 (cold) | Run 2 |
| --- | --- | --- |
| Import time | 13.1 s | 4.6 s |
| Time from “Transcribing on device…” to finished | 0.3 s | — |
| Peak resident memory | 414 MiB | — |
| History entries afterward | 1 | 2 |

In both runs the window ended idle with no status, all 9 cues unlabelled, no unsaved results and the new entry selected. The saved transcript has no `speaker` keys. The error read:

> “conversation.wav” was transcribed, but its speakers couldn’t be identified. The operation couldn’t be completed. Operation not permitted

The path is `TranscriptionModel.subtitleCues` (`LocalTranscription/TranscriptionModel.swift:267-280`). It calls `WhoSpeakerIdentifier.identify` (`LocalTranscription/SpeakerIdentification.swift:10-16`), catches the error, logs it, adds the message and returns unlabelled cues.

Caveats:

- The window itself wasn’t observed. The error text, cues, History save and status come from the app’s model, and an earlier offline check (UI-09) showed the window displays the model’s error.
- The sandbox makes a connection fail at once. A Mac without a connection would probably fail just as fast, with a different message such as “The Internet connection appears to be offline.” A network that silently drops requests (a captive portal, or DNS that never answers) wasn’t tested. Neither the app nor the SDK’s model download sets a timeout, so URLSession’s default of about 60 seconds without data applies, and the spinner could stay that long before the error.
- The second sentence of the error doesn’t say that Who needs a one-time download. The scenario’s rule was to fix only a hang or a missing message, so this isn’t counted as a bug. Mentioning the download in that message is a possible small improvement.
- The SDK leaves an empty `who/v0.3.1` folder after the failure. Run 2 shows it doesn’t stop a later attempt.

## Scenario 10: Who on long recordings

**Result: as expected.** Memory use is acceptable, so no length warning or processing in parts is needed.

Who decodes the whole file into memory as mono 16 kHz Float samples (SDK `Who+Audio.swift:13-14`) and normalises across the whole recording. The SDK already runs the model in 300-second parts (`Model.swift:150`, `Pieces.swift:18-21`). Only the decoded sample array grows with length. In the app, Who runs after Voz finishes (`TranscriptionModel.swift:255`, then `:273`).

The recordings were the synthetic noisy Spanish files from `build/manual-checks/`, `spanish-noisy-20min.wav` and `spanish-noisy-2hr.wav`. Models were already prepared. Each configuration ran three times; the tables give the range.

| File | Who alone | Who peak memory | Voz + Who + speaker labels + cues | Full-flow peak memory |
| --- | --- | --- | --- | --- |
| 20 minutes | 1.5 s | 285–289 MiB | 4.4–4.6 s | 331–345 MiB |
| 2 hours | 8.9 s | 664–668 MiB | 24.6 s | 731–747 MiB |

Memory is the peak memory footprint reported by `/usr/bin/time -l`. On the 2-hour file, Voz took 15.2 s, which matches the 15.34 s the Release app took in the earlier check. Speaker labels and cues took under 0.05 s. All 24,964 words got a label. Who’s whole-file decode sets the peak; Voz alone peaked at 277–313 MiB.

Who’s memory grows about 225 MiB per hour of audio, close to the 220 MiB an hour of 16 kHz Float samples takes, on top of about 210 MiB fixed. By that line, a 4-hour file would peak near 1.1 GiB and an 8-hour file near 2 GiB. Those are estimates; neither was run.

The largest peak was not about length. The first use with an empty Neural Engine compile cache took 164 s and peaked at about 1.45 GiB, on the 23-second file. This was seen once. Voz was also cold in that run, and its log came from an earlier version of the tool, without the sandbox header the other logs have.

Caveats:

- The machine was busy (load average 3.6–6.7, including a game client), so wall times were measured under load. Inference runs mostly on the Neural Engine.
- The window wasn’t measured. Its SwiftUI process adds its own baseline, and Ear’s language check, which runs before Voz, was left out.
- Each long file repeats one synthetic voice, so it finds one speaker. Long recordings with several speakers, and Macs with 8 GB or under memory pressure, weren’t tested.

## Reproduce

Both tools need SDK objects built with the current macOS SDK. The older `build/DerivedData` was built with SDK 27.0 and didn’t work with 27.2.

```sh
# Scenario 9
xcodebuild build -project LocalTranscription.xcodeproj -scheme LocalTranscription -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/scenario-9-10/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS=
build/scenario-9-10/offline-who/run.sh

# Scenario 10 (Release objects in build/scenario-9-10/long-file/DerivedData-Release)
build/scenario-9-10/long-file/run.sh who  build/manual-checks/spanish-noisy-2hr.wav who-2hr-1
build/scenario-9-10/long-file/run.sh full build/manual-checks/spanish-noisy-2hr.wav full-2hr-1
```

Each tool is built against those objects with the app’s non-UI sources. For scenario 10, replace `offline-who/check-offline-who` with `long-file/long-who`, add `-O`, and use `long-file/DerivedData-Release/Build/Products/Release`:

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
