# Mutation testing — November 1, 2026

Measured how well the automated suite catches real defects by planting them one at a time. `muter` is not installed, so 84 mutants were written by hand, each an exact one-line or one-expression change that a person could plausibly make: an off-by-one boundary, a dropped condition, a swapped fallback, a missing cleanup step. A script applied each mutant to the source, ran the full macOS suite with `xcodebuild … -destination 'platform=macOS,arch=arm64' test`, recorded which tests failed, and restored the file with `git checkout`. The source tree was confirmed clean after every round. No app source was changed.

The mutants cover the logic the suite can run without a model: subtitle cues and SRT/WebVTT output, cue realignment after edits, speaker attribution, release version checks, History saving, editing, deleting and clearing, the model’s save and edit guards, vocabulary terms, display formats, audio file validation, and language-sample reading. Code reached only through a real transcription was left out until a second round, below, along with the SwiftUI views, the update alert, logging, and message wording.

At the start, the two cached-model suites (“Cached Voz integration” and “Cached Ear language check”) skipped because the test app’s sandbox container had no models. Mutant AUD-02, which lets folders pass import validation, sent a test past validation into model preparation, and the app downloaded Voz v0.4.0 and Ear v0.2.0 (about 326 MB) into `~/Library/Containers/com.example.LocalTranscription/Data/Library/Caches/desert-ant-models/` at 00:29. From LNG-01, the last three mutants, onward, and in every later run, both suites ran and passed. The 80 first-round mutants before AUD-02 ran without them. A mutant that lets a test reach model loading can download models when the cache is empty.

## Results

| Round | Killed | Survived |
| --- | --- | --- |
| Existing 146 tests | 55 of 84 | 29 |
| With 12 new tests and one stricter test (158 tests) | 76 of 84 | 8 |

Two first-round kills, CUE-01 and UPD-08, crashed the test process with a Swift range or array-count trap rather than failing an expectation; they count as caught. Each of the 21 gaps was re-run after the new tests were added and was killed by the test written for it.

## Gaps closed

| Mutants | Defect | Test |
| --- | --- | --- |
| SUB-01, SUB-02 | A pause of exactly one second, or a cue of exactly six, splits the cue | `keepsAOneSecondPauseAndASixSecondCueTogether` |
| SUB-05 | “…” no longer ends a sentence | `endsCuesAtEverySentenceMark` |
| SUB-13, SUB-14, SUB-15 | Line-length boundary off by one: a 42-character line wraps, or two full 42-character lines don’t fit | `fillsLinesUpToTheLimit` |
| CUE-06 | Words replacing a run across a cue boundary go to the cue where the run ended | `wordsReplacingARunAcrossTheChangeGoWhereTheRunBegan` |
| CUE-07, CUE-08 | A second replacement after an unchanged word joins the previous cue | `aSecondReplacementAfterAKeptWordGoesToTheCueItReplaces` |
| SPK-06, SPK-07, SPK-08 | A word exactly one second from a turn loses its speaker | `wordsExactlyOneSecondFromATurnStillTakeItsSpeaker` |
| SPK-05 | A turn ending exactly as a word starts is dropped | `aWordStartingAsATurnEndsTakesItsSpeaker` |
| SPK-03 | Turns returned out of order mislabel words | `acceptsTurnsInAnyOrder` |
| UPD-02 | A release asset still uploading is offered for download | `rejectsADownloadThatIsStillUploading` |
| UPD-04, UPD-12 | HTTP 429 or 404 reports the wrong message | `reportsHTTPFailures`, which now checks each status’s message, not just that an error is thrown |
| HIS-04 | An entry saved before History finishes loading is listed twice | `loadingAfterASaveListsTheEntryOnce` |
| HIS-12 | A failed delete removes the summary first, leaving transcript text the list can’t show | `aFailedDeleteKeepsTheEntryListedToDeleteAgain` |
| HIS-13, HIS-14 | A failed Clear History reports success, or hides an entry still on disk | `aFailedClearReportsItAndKeepsTheEntryItCouldNotRemove` |

The History tests use `FailingFiles`, which can now also fail removing one chosen file.

## Remaining survivors

| Mutants | Why no test was added |
| --- | --- |
| CUE-03, SPK-04, HIS-07 | Equivalent. CUE-03’s following-cue context is always cue 0 where it applies; SPK-04 only adds turns whose overlap is zero; HIS-07 rewrites a file that a failed atomic write left unchanged. |
| MOD-01, MOD-02, MOD-03 | Transcription progress is set only during a real Voz transcription. No test covers these guards, which keep the bar from moving backwards, passing 100%, or taking updates from an earlier recording: the cached-model suite checks only that progress is cleared afterwards. Re-run on November 2 with both cached-model suites running, all three still survived. Testing them needs a seam to start a transcription without Voz. |
| SPK-01, SPK-13 | Low value. Zero-length turns and a zero-overlap tie inside a turn are unlikely from Who. |

## Flaky test

`aConflictingEditAsksAndCanKeepEitherVersion` waits a fixed 200 milliseconds (`TranscriptionModelTests.swift:519`) and then failed its check at line 520 several times once the cached-model suites were running alongside it; “Cached Ear language check” alone takes about 55 seconds, which is why the full suite went from about 2 seconds to 56. It failed this way before the new tests existed, during mutants that can’t affect editing. Alone it passed three of three runs; the full suite with the new tests passed three of four. Mutant kills credited only to this test were checked: MOD-05 fails at lines 508–515, before the wait, so it is a genuine kill.

The test now polls every 20 milliseconds, for up to five seconds, until window A shows the other version, matching `anotherWindowShowsTheEditedVersion`. The full suite, including both cached-model suites, then passed three of three runs, and again on `main` after merging on November 2: 158 tests, none skipped.

## Transcription code — November 2, 2026

With both models cached, a second set of 26 mutants covered the code only a real Voz or Ear run reaches: the import path through Voz, “Transcribe Anyway”, the import queue, model preparation, the shared `RecognizerStore`, and Ear identification. The Who model isn’t cached, so no mutant or test reaches Who; the new speaker test uses a stand-in.

| Round | Killed | Survived |
| --- | --- | --- |
| Existing 158 tests | 13 of 26 | 13 |
| With 3 new tests (161 tests) | 18 of 26 | 8 |

The script now counts a run that fails without a failing test, such as a crash, as killed instead of a build error; rerun over the first round’s logs, it changes only CUE-01 and UPD-08 to killed.

### Gaps closed

| Mutants | Defect | Test |
| --- | --- | --- |
| TRX-08 | “Transcribe Anyway” drops the names and terms entered when the file was imported | `transcribingAnywayUsesTheNamesAndTermsFromImportTime` |
| TRX-21, TRX-09 | Speaker identification is ignored for imports, or for a file transcribed despite a language warning | `identifiesSpeakersWhenAskedEvenAfterALanguageWarning` |
| REC-02, REC-03 | Every request loads its own copy of Voz, or the store never reports it loaded, so every import says “Loading Voz…” | `sharesOneLoadOfVozAcrossRequests` |

All five were re-run after the tests were added and each was killed by its test. The full suite passed: 161 tests, none skipped.

### Remaining survivors

| Mutants | Why no test was added |
| --- | --- |
| TRX-15, TRX-19, TRX-20 | Guards against a second preparation running alongside an import or another preparation. The shared store loads Voz once, so the end state is the same; only the status shown mid-run differs, and testing that needs control over when loading finishes. |
| TRX-17 | Equivalent with Ear cached: fetching the language model after a transcription does nothing once it’s on disk. |
| REC-01 | A failed model load is never retried. Testing it needs a load that fails, which needs a seam in front of Voz. |
| TRX-11 | Saving the recording length as the processing time. Every check that could catch it, such as processing time being shorter than the recording, depends on machine speed. |
| EAR-01, EAR-02 | Treating every detection as reliable, or passing 22 kHz samples as 16 kHz. Ear still identifies every fixture reliably and correctly either way, so catching these needs a recording Ear is unsure about. |

The mutant list, the script, per-mutant logs, and JSON results are in the ignored `build/mutation-testing/` folder. Re-run with `python3 -I build/mutation-testing/run_mutants.py [mutant IDs]`, adding `MUTANTS=mutants_trx RESULTS=results-trx.jsonl` in front for the transcription mutants; `--check` confirms every mutant still matches the source exactly once.
