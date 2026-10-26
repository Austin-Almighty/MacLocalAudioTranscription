# Who speaker identification — October 24, 2026

The app links the Who product from the existing Desert Ant SDK 4.0.0 pin and uses Who weights v0.3.1, default float16 precision. No dependency version changed. The [pinned SDK documentation](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.0.0/docs/models/who.md) describes the API and model limits.

## Automated checks

- The final macOS Xcode test run passed: 112 tests across 20 suites, including ten new speaker tests. Fifteen existing tests requiring the default Voz/Ear caches were skipped. Log: `/tmp/local-transcription-who-tests-final.log`.
- Speaker tests cover cue splitting, timing retention, overlapping speech, ties, gaps, invalid turns, 10,000 words and turns, speaker labels in all export formats, caption line limits, old History JSON, history reopening, editing and reverting, disabled identification, empty results, failed identification, and per-file queue settings through language warnings.
- The unsigned iOS device build passed. Log: `/tmp/local-transcription-who-ios-final.log`. This is a build check, not physical iOS inference.
- The standalone Release Mac app rebuilt successfully and its ad hoc signature passed verification. Output: `dist/LocalTranscription.app`. Log: `/tmp/local-transcription-who-release-final.log`.

## Real model checks

Generated a 23.126625-second conversation with macOS Samantha and Daniel voices. Downloaded Who into `build/who-verification/models/`, separate from the normal app cache, and used the existing isolated Voz cache. SDK model verification passed. The app’s actual speaker-attribution and subtitle-rendering code was compiled into the verification tool.

Who returned two speakers: the first from 0 to 10.16 seconds, the second from 10.28 to 22.93 seconds. Voz recognized 59 words; all 59 received speaker labels. The result begins:

> Speaker 1: Good morning Daniel. Today we are testing speaker identification in our local transcription app.
>
> Speaker 2: Thank you, Samantha. The audio stays on this computer.

The first measured diarization after preparation took 0.537 seconds. A second process under `Scripts/offline.sb`, which denies outbound networking, produced the same speaker labels in 0.517 seconds. A curl probe under the same restriction failed to resolve Hugging Face. Initial download and Neural Engine preparation are excluded from those inference times and can take several minutes. These short synthetic recordings verify integration, not accuracy on real meetings or overlapping human voices.

Tool source, audio, model files, online and offline logs, JSON reports, and generated text/SRT/WebVTT files are in the ignored `build/who-verification/` folder. The normal app’s transcripts and preferences were not used.

## Native app check

Launched a disposable Release copy with bundle ID `com.example.LocalTranscription.WhoChecks` and `CFFIXED_USER_HOME` pointing to `build/who-verification/ui-home/`. Its model cache links to the isolated verified model folders. The inspector exposed Identify Speakers (Who), initially off. Enabled it and imported the synthetic conversation through the native file picker. The app showed its speaker-identification spinner while Core ML prepared Who; a process sample confirmed it was waiting on Neural Engine compilation off the main thread.

The completed native interface showed the two correctly separated speaker paragraphs and “Speakers 2” in Recording Info. Turning the switch off during preparation did not remove the running import’s labels. The saved History JSON contains speaker numbers 0 and 1 in the cues and keeps them separate from the editable spoken text. Relaunching the test copy listed the saved entry. Native Copy and export dialogs were not repeated; export content is checked by the automated suite and real-model tool above.

## Scope and limits

Identify Speakers is off by default and applies only to new imports. Old saved entries decode without a speaker field. The app retains every recognized word; words with tied or absent speaker overlap stay unlabelled. Editing realigns spoken words to the original labelled cues. It does not rerun voice identification, identify people by name, or assign two simultaneous voices to the same word. Renaming speakers and reanalysing existing entries are outside this change.

Physical iOS inference, VoiceOver speech, and accuracy on natural conversations remain unverified.
