# Failed edit saves (UI-23) — October 28, 2026

Checked an unsigned Release build of the uncommitted Discard Edits change on macOS 27.0.1. The copy ran with bundle ID `com.example.LocalTranscription.UI23` and `CFFIXED_USER_HOME` set to `build/ui23/home/`, so its History and preferences stayed separate from the normal app. History was seeded with two entries, alpha.wav and beta.wav. The interface was driven through macOS accessibility (System Events) and checked by reading the window’s accessibility tree.

## Results

History was made unwritable (`chmod 555`) while alpha.wav was being edited.

| Step | Result |
| --- | --- |
| Type, then wait for autosave | **Passed.** An “Edits Not Saved” alert showed the real permission error with Discard Edits and Keep Editing. |
| Keep Editing, type again, wait for autosave | **Passed.** The alert closed and the repeated autosave failure stayed quiet. |
| Done | **Passed.** The alert returned and editing stayed open. |
| Select beta.wav | **Passed.** The alert returned and alpha.wav stayed shown. |
| Copy Transcript | **Passed.** The alert returned and nothing was copied. |
| Save Transcript… | **Passed.** The alert returned and no save dialog opened. |
| Close the window | **Passed.** The window stayed open with the alert. |
| Quit from the app menu | **Passed.** The app kept running and showed the alert. |
| Restore write access, then Done | **Passed.** The edit was saved, the original transcript was kept beside it, and editing ended. |
| Edit again with History unwritable, then Discard Edits | **Passed.** Editing ended, the last saved text was shown, and the file on disk was unchanged. |
| After discarding, select beta.wav, close the window, and quit | **Passed.** Each worked while History was still unwritable. |

A recording finishing while a draft can’t be saved (finding #2) was not repeated in the app. It needs a real transcription during the failure and is covered by the automated tests. Screenshots were not kept: the window capture picked the alert’s window and came out blank, so the accessibility tree is the record.
