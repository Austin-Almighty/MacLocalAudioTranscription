# Local Transcription: Failure Scenarios and Test Plan

Oct 28, 2026 · Austin Liao

## Summary

Fifteen failure scenarios remain after PR #2. Six of them looked like real bugs, four of which could lose a transcript or an edit. Tests in PR #4 confirmed scenarios 1, 2 and 4, and PR #5 fixed them; PR #6 fixes gaps a later review found in those fixes. Scenario 3 did not reproduce in a manual check, because SwiftUI queued the two alerts. The others are still unconfirmed: each comes from reading the code, not from a failing test.

The plan is to confirm before fixing. Scenarios 1, 2, 4 and 7 each need only a unit test to confirm or rule out; scenario 3 needs a short manual check. Fixes follow only for what fails.

This follows the review of PR #1 (Who speaker labels and edit protection) and the fixes proposed in PR #2 (Discard Edits and waiting recordings).

## Likely bugs

These six are the priority: 1, 2, 4 and 5 can lose words without warning, 3 can hide a message, and 6 can lose a draft on iPhone.

| # | Scenario | Why we suspect it | How to confirm | Fix plan |
| --- | --- | --- | --- | --- |
| 1 | Two recordings finish while an edit can’t be saved, and History can’t store either | Only the latest waiting recording is kept, so the first is replaced without notice | Unit test: call `finishTranscription` twice while blocked, discard, check both transcripts | Keep every waiting recording; retry saving each to History when editing ends; name any still unsaved |
| 2 | The same entry is edited in two windows at once | Each window saves its own draft, and an editing window skips reloading the other’s version, so the last save wins | Unit test: two models share one History; both edit; A saves, then B saves; check A’s words | Before saving, compare the entry’s edited date with the one editing started from; on a mismatch, ask which version to keep |
| 3 | Two alerts are due at once | The general error, Edits Not Saved and the language warning are separate alerts on one view, and SwiftUI may drop one | Manual check in the isolated app: fail a save, then let a recording finish | Drive all prompts from one queue, presented one at a time in order |
| 4 | Quitting with an unsaved recording on screen | Quitting only checks drafts; a recording History couldn’t store is discarded silently | Unit test on the app delegate’s quit check with an unsaved result shown | Ask before quitting, with Save Transcript… and Quit Anyway (PR #5); PR #6 asks before closing a window too, with a native alert |
| 5 | A save that half succeeds | `TranscriptHistory.update` writes the original copy, the transcript, then the summary; if the summary fails, other windows don’t see the edit | Needs a file-operation seam that fails one chosen write | Restore the previous transcript when the summary write fails, as `save` already removes it |
| 6 | iPhone: the app is backgrounded and killed while saves fail | iOS has no close or quit guard, and the background save is the quiet kind | Simulator test once the simulator runtime is updated, or a model test of the background path | Write each draft to a recovery file and offer it at the next launch |

## Speaker labels (Who)

These affect label quality more than data safety; no recognized word is ever dropped. Scenario 7 is the one real conversations will hit first.

| # | Scenario | How to test | Fix plan |
| --- | --- | --- | --- |
| 7 | Words in gaps between speaker turns, or tied between two speakers, get no label and become separate unlabelled paragraphs | Unit test with turns that leave short gaps; check the plain text for paragraphs without “Speaker N:” | Give such a word the nearest turn’s speaker within a short window, else the previous word’s |
| 8 | Editing across a speaker change (deleting all of one speaker’s words, pasting across the boundary) gives words the wrong speaker | Unit test of cue realignment with labelled cues | Decide the expected behavior first, then test it |
| 9 | First use of Who while offline | Isolated app with an empty Who cache under `Scripts/offline.sb` | Expected: transcript kept, a clear error; fix only if it hangs or says nothing |
| 10 | Long recordings: Who reads the whole file | Run the 20-minute file under `build/manual-checks/`; record time and peak memory | If memory is too high, warn above a length or process in parts |
| 11 | Voz word timings out of order or overlapping; the matching code assumes time order | Randomised test with shuffled and overlapping words | Sort words by start time before matching |
| 12 | The user types “Speaker 1:” into the text, and the view shows “Speaker 1: Speaker 1: …” | Unit test of the plain-text display | Low priority; likely leave as is |

## History and files

These probably work but have never been tested.

| # | Scenario | How to test | Fix plan |
| --- | --- | --- | --- |
| 13 | The original copy is missing when reverting (deleted by hand or by a sync tool) | Unit test: delete the original file, revert, expect a clear error with the edit intact | Hide Revert to Original when no original copy exists |
| 14 | A really full disk, not just a read-only folder; partial writes may behave differently | Mount a tiny disk image (`hdiutil create -size 2m`) as the isolated app’s home | Depends on what the check shows |
| 15 | The entry is deleted in another window while Edits Not Saved is open | Unit test with two models: the alert state clears, the draft is dropped, nothing crashes | Fix only if the test fails |

## Test tools to build

Five pieces of test setup cover all fifteen scenarios. Only the first needs a change to the app’s code.

- **File-operation seam in History.** Put `TranscriptHistory`’s reads and writes behind a small protocol, with a test version that fails one chosen write. A read-only folder only tests “everything fails at once”. Needed for 5; helps 13 and 14.
- **Randomised tests** for speaker matching and cue realignment. Invariants: no word is lost, timings never change, a label only comes from an overlapping turn. Covers 7, 8 and 11.
- **Two models sharing one History** to stand in for two windows. The existing tests already use this setup. Covers 2 and 15.
- **A saved UI script.** Keep the accessibility automation from the UI-23 check as `Scripts/ui-check.sh`, so manual checks such as 3 can be re-run.
- **A tiny disk image** as the isolated app’s home, for real disk-full behavior. Covers 14.

## Plan and order of work

Four phases, each a separate PR. Every fix starts as a failing test, as in PR #2.

1. **Confirm.** Write tests only, no fixes, for 1, 2, 4, 7, 11, 13 and 15, and run the manual check for 3. Result: a list of which scenarios are real.
   - [x] Unit tests for 1, 2 and 4 (PR #4)
   - [ ] Unit tests for 13 and 15
   - [ ] Randomised tests for 7 and 11
   - [x] Manual check for 3 in the isolated app: not reproduced; the language warning wasn’t tried
2. **Fix data loss.** Fix whatever phase 1 confirmed among 1, 2 and 4; add the file-operation seam, then test and fix 5.
   - [x] Fixes for 1, 2 and 4 (PR #5, with gaps fixed in PR #6)
   - [ ] File-operation seam in History
   - [ ] Test and fix for 5
3. **Speaker quality.** Fix 7 and 11, settle the expected behavior for 8, and measure 9 and 10.
   - [ ] Nearest-turn fallback (7) and sorting (11)
   - [ ] Decision and tests for 8
   - [ ] Offline first use (9) and long-file measurements (10)
4. **Platform.** Update the simulator runtime, then test 6; run the disk-full check for 14.
   - [ ] Simulator runtime updated
   - [ ] Draft recovery for 6
   - [ ] Disk-full check for 14

Scenario 12 stays open unless someone reports it.

## Already verified

PR #2 covered these, so they are not repeated here:

- A failed save offers Discard Edits and Keep Editing; switching, Revert, Copy, Export, closing and quitting no longer trap the window. Covered by model tests and the UI-23 check in the app (`verification/edit-save-failure-check-results.md`).
- Repeated autosave failures are reported once.
- A recording that can’t be saved while a draft can’t be saved waits and appears when editing ends. Covered by model tests only, not in the app.
- The full macOS suite passed with 118 tests after PR #2, and passes with 130 after PR #6. The 17 real-model tests are skipped because the models aren’t cached on the test machine.
