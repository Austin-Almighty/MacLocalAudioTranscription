# App test cases

Run the automated tests with **Product → Test** in Xcode, or:

```sh
xcodebuild test -project LocalTranscription.xcodeproj -scheme LocalTranscription \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=NO
```

## Automated coverage

| Area | Case | Expected result |
| --- | --- | --- |
| Initial state | Create a new transcription session | No transcript, file, timings, error, or active operation. |
| File validation | Import HTTP, HTTPS, or FTP URLs | Reject them without loading a model or leaving the session busy. |
| File validation | Import a missing file, then retry | Both attempts report an error; retry remains possible and no result is created. |
| File validation | Import a directory | Reject it before loading a model. |
| Audio formats | Transcribe AIFF, WAV, MP3, M4A/AAC, raw AAC, FLAC, and CAF | Recognize the known spoken sentence and report the correct file name and valid duration/timing. |
| File names | Import a file named “訪談 café 🎙️.aiff” | Recognize the speech and preserve the original file name. |
| Result retention | Successfully transcribe, then import a missing file | Report the new error while preserving the previous transcript, file name, and timings. |
| Recovery | Import corrupt WAV data, then a valid recording | Corrupt data reports an error; the next recording succeeds and clears it. |
| Model preparation | Prepare an already loaded model twice after transcription | Stay ready and preserve the transcript. |
| Text export | Round-trip empty text, English, multiple lines, accents, and emoji | Preserve the text exactly. |
| Text encoding | Export “你好” followed by a newline | Write the known UTF-8 bytes without a byte order mark. |
| Invalid text | Read malformed UTF-8 | Report a Cocoa error. |
| Invalid text | Read a directory as a transcript | Report a Cocoa error instead of crashing. |
| Subtitles | Group timed words with sentence ends, a pause over one second, more than six seconds, or more than two 42-character lines | Start a new cue at each boundary; no cue exceeds six seconds or two lines of 42 characters. |
| Subtitles | Words with zero duration followed closely by another cue | Extend cues to half a second without overlapping the next cue. |
| Subtitles | Format cues as SRT and WebVTT, including a start past one hour and non-ASCII text | Produce exact numbered SRT (`HH:MM:SS,mmm`) and WebVTT (`HH:MM:SS.mmm`) output. |
| Subtitles | Export with no recognized words | Produce no cues, an empty SRT file, and a header-only WebVTT file. |
| Export formats | Export text, SRT, and WebVTT | Use `.txt`, `.srt`, and `.vtt` with matching file types the document can write. |
| Progress | Report progress with no transcription or download running | Ignore the late update and show no progress. |
| Subtitles | Transcribe each fixture with the real model | Produce cues within the recording’s duration and clear transcription progress afterward. |
| Language check | Detections of Chinese, Japanese, English, German, uncertain Chinese, and uncertain Swedish | Warn only for confident detections of languages Voz doesn’t support. |
| Language check | Read all seven fixture formats, a seven-minute stereo recording, and non-audio data | Short files are read whole; long ones as six evenly spaced 30-second mono segments from start to end; non-audio is rejected. |
| Language check | A stand-in identifier reports confident Chinese, then the warning is dismissed | Warn without loading Voz, leave the app idle, and keep the previous result. Invalid files report an error without a warning. |
| Language check | Identify each English fixture with the real Ear model | Detect reliable English and transcribe normally. |
| Language check | Transcribe English, then import the Chinese fixture, then choose Transcribe Anyway | Warn before transcribing while keeping the English result; Transcribe Anyway completes and records Chinese. |
| Language check | Language identification throws | Transcribe normally with no language shown. |
| Formatting | Format recording lengths under and over a minute and hour, processing times, and Taiwan and German locales | “5.8 s”, “11m 28s”, “2h 2m 5s”, “0.13 s”; “11分28秒” and “5,8 s” in other locales. |
| Formatting | List the supported languages | 25 names in the person’s language, sorted, including English and not Chinese. |
| File validation | Import a web address, a missing file, a folder, and an unreadable file | Each error names the file and says why: not on this device, no longer exists, a folder, or no permission. |
| History | Save entries with a Unicode file name, cues, and with and without a language, then reopen the store | A new session lists them newest first and reloads each transcript and cue exactly. |
| History | Delete one entry, then clear history | Both files of a deleted entry are removed; clearing leaves no saved transcripts. |
| History | Clear history with damaged, newer-format, and orphaned transcript files present; save when the summary can’t be written | Clearing removes every history file; a failed save leaves no transcript file behind. |
| History | Transcribe three seconds of silence | Nothing is recognized and nothing is saved. |
| Editing | Realign cues after no change, a typo, a replaced first word, insertions mid-text and at the start, a deleted cue, a pasted replacement, empty text, line breaks, and Unicode | Timings never change; words land in the cue they replace or follow; emptied cues are dropped; pasted text is spread across cues. |
| Editing | Grow a cue past one line, then past two | Wrap onto two lines while it fits; beyond that keep every word on one line. |
| Editing | Edit twice, reopen history, revert; delete an edited entry | The latest edit and its date persist; the original is kept from the first edit only and restored by Revert; deleting removes all three files. |
| Editing | Edit and choose Done; switch entries mid-edit; stop typing for a second; delete the entry being edited; revert | Each saves to the entry being edited with realigned cues, autosave waits a second, deleting drops the draft, and revert restores the original. |
| Editing | Edit in one window while another shows the same entry | The other window reloads the edited version. |
| Editing | A queued recording finishes while editing another entry | The draft is saved to its own entry before the new result is shown. |
| Editing | Try to edit with no saved transcript | Editing doesn’t start. |
| Import queue | Sort the seven fixture formats, a text file, a folder, and a web address | The recordings are accepted in order; the rest are rejected. |
| Import queue | Import only a text file | Name it in an error, queue nothing, and load no model. |
| Import queue | Queue three recordings that sound like Chinese, add one while paused, cancel, clear the queue, cancel again | Each warning pauses the queue with the rest waiting; Cancel moves to the next; a file added while paused waits; Clear Queue leaves nothing to do. |
| Import queue | Queue a missing file and a folder | Report each by name in one message and finish with an empty queue. |
| Import queue | Transcribe English, a missing file, and two more English formats in one batch | Save the three recordings in order, report the missing one by name, and show the last. |
| Import queue | Batch English, Chinese, and English with the real language model; choose Transcribe Anyway | The Chinese file pauses the batch with one file waiting; after the decision all three are saved in order. |
| History | Load a folder with a damaged file and an entry from a newer format | Skip both without deleting them; load the rest. Loading before anything is saved creates no folder. |
| History | Select saved entries, select nothing, and delete the shown entry | Show each entry’s transcript, cues, timings, and language; return to the empty view when nothing is selected or the shown entry is deleted. |
| History | Delete an entry shown in two windows, and clear history | Every window showing it returns to the empty view; windows showing other entries are unchanged. |
| History | Select an entry whose transcript file is missing | Report an error and show the empty view. |
| History | Transcribe each fixture, fail an import, decline and then accept the Chinese warning | Successes are saved and selected; failures and declined recordings add nothing; the earlier transcript can be selected again. |
| App updates | Compare major, minor, patch, equivalent, and older versions | Numeric ordering offers only a newer version; `1.0` and `1.0.0` are equal. |
| App updates | Receive malformed versions, draft/prerelease/unpublished releases, missing assets, or unofficial download URLs | No download is offered. |
| App updates | Receive HTTP 404, 403, 429, or 500 | Report unavailable releases, rate limits, or server errors instead of claiming the app is current. |

Every test uses its own temporary history folder, removed afterward, so tests never read or change saved transcripts. The real-model suite runs serially on Apple Silicon macOS only when `Voz.isDownloaded()` passes the SDK’s cache-integrity checks. Otherwise it is explicitly skipped. It does not download model weights. Prepare the model in the app first, then rerun the tests. The language-check suite also requires Ear’s model, which the app fetches after Voz is ready; the other real-model tests use a stand-in identifier so they never trigger that download. A sandboxed Xcode build may use a different cache from the locally packaged app.

The format fixtures are versions of the same locally synthesized recording, generated using macOS’s Samantha voice and converted with FFmpeg. Their spoken reference is:

> This is a local speech recognition test. The quick brown fox jumps over the lazy dog.

FFmpeg is needed only to regenerate the fixtures; running the tests uses the bundled files. The Chinese text and file name test Unicode handling, not Chinese speech recognition. Voz does not support Chinese speech. `speech-zh.m4a` is 8.5 seconds of Taiwan Mandarin synthesized with macOS’s Eddy (zh_TW) voice and converted with `afconvert`; Ear identifies it as Chinese with full confidence, so it exercises the unsupported-language warning.

## Manual UI and device checks

These cases supplement the automated suite. Results from the October 16, 2026 run are recorded in the [check report](verification/manual-check-results.md); partial checks and remaining steps are identified there.

| ID | Setup and steps | Expected result |
| --- | --- | --- |
| UI-01 | Launch the packaged app with its model cached. | The model loads automatically, Import becomes enabled, and the empty recording state is shown. |
| UI-02 | Press ⌘O and choose any bundled audio fixture. | A native Open dialog accepts the file; the correct transcript and recording metadata appear. |
| UI-03 | Open Import, then cancel. | The current transcript remains available and the app is not left busy. |
| UI-04 | Click Copy Transcript and paste into a text editor. | The pasted text exactly matches the transcript. |
| UI-05 | Press ⌘S, choose a destination, and export. | A UTF-8 `.txt` file contains the transcript and has a name derived from the audio file. |
| UI-06 | Open Save Transcript, then cancel. | No new file is written and the existing transcript stays visible. |
| UI-07 | Show and hide Recording Info using the toolbar and View menu; resize the window. | Details remain correct, the transcript stays readable, and controls do not overlap. |
| UI-08 | Import a long recording and import another while it is processing. | Import stays available; the second file joins the queue and the status bar shows “1 more queued”; the window stays responsive and both results are saved in order. |
| UI-09 | Use a fresh test account or app container with no model cache. Start a model download, interrupt networking, then retry. | The failure is reported, controls become usable again, and retry completes when connectivity returns. Do not remove your working cache for this check. |
| UI-10 | Prepare the model, disconnect networking, then transcribe a fixture. | Local inference succeeds with no model-weight download. SDK license metadata requests may fail independently of inference. |
| UI-11 | Check light and dark appearances, Reduce Transparency, larger text, keyboard navigation, and VoiceOver. | System controls adapt, text remains legible, and actions have accessible names. |
| UI-12 | Import a long, noisy, non-English recording in a supported language. | The app finishes without losing its prior result on failure; a person checks recognition accuracy. |
| UI-13 | In View, reset transcript size, increase it four times, and narrow the window with the inspector visible. Then check both size limits and reset. | Transcript renders at 200% with wrapping and no clipped words. Increase disables at 300%, Decrease at 75%, and Actual Transcript Text Size restores 100%. |
| UI-14 | Choose LocalTranscription → Check for Updates with no published release, then retry offline. | A clear error appears; the app stays usable, no transcript is lost, and checking can be retried. |
| UI-15 | After publishing a newer stable release with its Mac ZIP, check for updates, choose Later, then check again and choose Download Update. | Later leaves the app unchanged; Download Update opens the official ZIP in the default browser. Equivalent/older installed versions offer no downgrade. Homebrew users see upgrade instructions. |
| UI-16 | Transcribe a fixture, choose Export Subtitles → SubRip, then WebVTT, and open both files in QuickTime Player or VLC. | Both files save with the audio file’s name and correct extension, and captions appear in time with the speech. |
| UI-17 | Turn Show Timestamps on and off in Recording Info, then change transcript text size. | Each cue shows its start time; the plain transcript returns when turned off; text size applies in both views. |
| UI-18 | With no model cached, choose Download Model; then import a long recording. | The status bar shows a filling bar and percentage during the download, then a spinner while the model prepares. During transcription the bar fills, then gives way to a spinner until the transcript appears; it never sits at 100%. |
| UI-19 | Import `LocalTranscriptionTests/Fixtures/speech-zh.m4a`, choose Cancel; import it again and choose Transcribe Anyway. Then import an English fixture. | The Language Not Supported alert names Chinese; Cancel keeps the earlier transcript; Transcribe Anyway shows text and Language “Chinese”; the English recording shows Language “English” with no alert. |
| UI-20 | Transcribe two recordings, quit and reopen the app, select each entry, delete one with the Delete key, then use More → Clear History and confirm. Open a second window while deleting. | Both entries survive relaunch and show their own transcripts; deleting the shown entry empties every window showing it; Clear History asks first and empties the list. |
| UI-21 | Drag three fixtures and a text file from Finder onto the window, then drop more while the first is transcribing; try Clear Queue. | The window highlights while dragging; the text file is named in an error; recordings are transcribed in order with the queued count shown; Clear Queue stops the waiting files. |
| UI-22 | Select a transcript, choose Edit, fix a word, use Undo and Redo, press Delete inside the text, and choose Done. Export SRT. Then Revert to Original and confirm. | Undo works and the cursor stays put while autosave runs; Delete edits text without deleting the history entry; Done shows the fix and “Edited” in Recording Info; the SRT has the fix at the original timing; Revert restores the original. |

Offline inference, empty-cache failure and retry, long/noisy Spanish audio, light/dark appearance, import/export cancellation, clipboard copying, inspector controls, and window resizing have now been exercised. The [accessibility follow-up](verification/accessibility-check-results.md) also checked keyboard navigation, Reduce Transparency, transcript enlargement to 200%, size limits, heading semantics, and the accessible progress name. System preferred reading size is unsupported; the app provides transcript-specific size controls. Spoken VoiceOver and interruption partway through a download remain unverified. Synthetic recordings are regression checks, not accuracy benchmarks.
