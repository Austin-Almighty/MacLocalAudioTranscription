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
| App updates | Compare major, minor, patch, equivalent, and older versions | Numeric ordering offers only a newer version; `1.0` and `1.0.0` are equal. |
| App updates | Receive malformed versions, draft/prerelease/unpublished releases, missing assets, or unofficial download URLs | No download is offered. |
| App updates | Receive HTTP 404, 403, 429, or 500 | Report unavailable releases, rate limits, or server errors instead of claiming the app is current. |

The real-model suite runs serially on Apple Silicon macOS only when `Voz.isDownloaded()` passes the SDK’s cache-integrity checks. Otherwise it is explicitly skipped. It does not download model weights. Prepare the model in the app first, then rerun the tests. A sandboxed Xcode build may use a different cache from the locally packaged app.

The format fixtures are versions of the same locally synthesized recording, generated using macOS’s Samantha voice and converted with FFmpeg. Their spoken reference is:

> This is a local speech recognition test. The quick brown fox jumps over the lazy dog.

FFmpeg is needed only to regenerate the fixtures; running the tests uses the bundled files. The Chinese text and file name test Unicode handling, not Chinese speech recognition. Voz does not support Chinese speech.

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
| UI-08 | Import a long recording and try importing again while it is processing. | Import is disabled during the operation; the window stays responsive and one result is shown. |
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

Offline inference, empty-cache failure and retry, long/noisy Spanish audio, light/dark appearance, import/export cancellation, clipboard copying, inspector controls, and window resizing have now been exercised. The [accessibility follow-up](verification/accessibility-check-results.md) also checked keyboard navigation, Reduce Transparency, transcript enlargement to 200%, size limits, heading semantics, and the accessible progress name. System preferred reading size is unsupported; the app provides transcript-specific size controls. Spoken VoiceOver and interruption partway through a download remain unverified. Synthetic recordings are regression checks, not accuracy benchmarks.
