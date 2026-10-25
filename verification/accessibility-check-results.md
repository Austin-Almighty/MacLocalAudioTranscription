# Accessibility follow-up — October 16, 2026

Checked the packaged app on Apple M4 Pro, macOS 27.0.1. UI interactions used a separate app copy with bundle ID `com.example.LocalTranscription.AccessibilityChecks`; the normal app’s preferences and transcripts were not used.

## Results

| Check | Result |
| --- | --- |
| Keyboard navigation | **Passed.** Temporarily enabled macOS Keyboard → Keyboard navigation. Tab reached the empty-state Import button, Supported Languages link, toolbar Import, and Recording Info. Disabled Copy and Save were skipped. Shift-Tab moved backward; Space toggled the inspector and opened Import. |
| Keyboard import | **Passed.** Opened the native file picker with the keyboard, used ⌘⇧G, typed the fixture path, selected it with arrow keys, and pressed Return. The expected transcript appeared. |
| Keyboard Copy and Save | **Passed for control access.** Tab reached Copy with a visible focus ring; Space activated it. The next Tab and Space opened Save. Escape cancelled Save and preserved the transcript. Clipboard paste correctness was checked in the [earlier run](manual-check-results.md). |
| Reduce Transparency | **Passed.** With the actual macOS preference enabled, toolbar, inspector, and bottom status surfaces became opaque. Content and controls remained readable. Restored the preference afterward. |
| System preferred reading size | **Unsupported by this app.** Increased Accessibility → Display → Text size from Default to the maximum 42 pt. This third-party app was absent from the supported-app list, and its text did not enlarge. Restored Default. Apple describes this setting as applying to the supported apps shown in the panel; see [Apple’s instructions](https://support.apple.com/en-gb/guide/mac-help/mchlbc4c53ca/mac). |
| Transcript text enlargement | **Passed after the change below.** View → Increase Transcript Text Size enlarged the transcript in 25% steps. At 200%, all words wrapped without clipping in a window approximately 760 points wide, with the inspector still visible and toolbar controls available. This enlarges transcript content, not every inspector or system-control label. |
| Text-size limits and reset | **Passed.** Increase became disabled at 300%; Decrease became disabled at 75%. Actual Transcript Text Size restored 100%. The ⌘0 reset shortcut also worked. Menu actions were verified; the automation’s equals-key input did not establish a successful increase-shortcut check. |
| Semantic transcript heading | **Passed after the change below.** The accessibility tree now exposes a separate `heading Transcript` before the transcript text. Previously they were combined into one text element without a heading role. |
| Accessible progress name | **Passed after the change below.** During a two-hour fixture import, the tree exposed `busy indicator Description: Transcribing on device…` and a disabled Import action. The import completed and restored the current transcript and metadata. This checks the accessible name, not the timing of spoken announcements. |
| Current result values | **Passed.** After the long import, the tree reported `spanish-noisy-2hr.wav`, `7200.0 seconds`, `15.24 seconds`, `Voz Ready`, and the Spanish transcript. |
| VoiceOver speech and navigation | **Not verified.** Enabled VoiceOver, completed its welcome flow, and confirmed the screen-reader process started. Its caption-panel preference was already enabled. The background app could not be inspected reliably through automation; subsequent command attempts encountered timeouts and changed-focus rejections, and VoiceOver returned to off. No successful spoken transcript, control announcement, heading-navigation, or completion-announcement result is claimed. |
| Build and regression tests | **Passed.** Release app rebuilt and its ad hoc signature verified. All 13 tests, covering 24 parameterized cases, passed in 11.127 seconds. Log: `/tmp/local-transcription-accessibility-tests.log`. |

## Changes

- Added native View-menu transcript text-size controls with ⌘=, ⌘−, and ⌘0 shortcuts. The content scale is saved per app through `AppStorage`. The iOS transcript retains its existing semantic text style.
- Marked “Transcript” as an accessibility heading.
- Gave the progress indicator the current operation’s accessible name.

These checks do not establish full Larger Text or VoiceOver conformance. The transcript zoom does not scale all app text, and readable accessibility-tree content is not a substitute for a successful screen-reader session.

## Preferences restored

| Preference | Original | Final observed state |
| --- | --- | --- |
| Reduce Transparency | Off | Off |
| Preferred reading size | Default, slider 4 | Default, slider 4 |
| Keyboard navigation | Off | Off |
| VoiceOver | Off | Off |
| VoiceOver caption panel | Enabled | Unchanged |

The disposable app’s transcript size was reset to 100%. The test app and the settings windows opened for the check were closed.

## Remaining human VoiceOver check

1. Launch the rebuilt app in `dist/LocalTranscription.app` and enable VoiceOver. Complete its “Use VoiceOver” welcome prompt if shown.
2. Navigate with the configured VoiceOver modifier and arrow keys. Confirm that Import, Copy, Save, and Recording Info have meaningful names and operable actions.
3. Import a known recording. Confirm that “Transcript” is reachable as a heading, the text is read correctly, and file, duration, processing time, and model readiness are understandable.
4. Check busy/completed announcements, error-alert focus and dismissal, and focus return after native dialogs.
5. Restore VoiceOver to the user’s preferred state.

Apple’s [caption-panel guide](https://support.apple.com/en-am/guide/voiceover/unac078/mac) describes its display of spoken text. Neither caption output nor audible speech was successfully captured in this run.

## Recheck with the History sidebar — October 22, 2026

The History sidebar narrows the transcript column, so the 200% layout and keyboard navigation were checked again on the Release build of commit `3e9bed6`, macOS 27.0.1. A copy with bundle ID `com.example.LocalTranscription.Recheck` ran with `CFFIXED_USER_HOME` set to a test folder under `build/accessibility-recheck/`, so its History and preferences stayed separate from the normal app. Keyboard navigation was enabled for the check and turned off again afterward; the test app’s transcript size was reset to 100%.

| Check | Result |
| --- | --- |
| 200% transcript at minimum width | **Passed.** With two History entries, the inspector open, and the window at its 980-point minimum width, View → Increase Transcript Text Size four times reached 200% and Increase stayed enabled. The transcript wrapped within its column without clipping, the sidebar entries and inspector values stayed readable, and all toolbar controls remained visible. The 5.8-second fixture fills four lines, so scrolling a long transcript at 200% was not rechecked. |
| Tab order | **Passed.** Tab reached 12 stops in order and wrapped: More, Toggle Sidebar, Import, Edit, Copy, Save, Export Subtitles, Recording Info, Show Timestamps, Names and Terms, Supported Languages, and the History list. Shift-Tab followed the same order backward. Each toolbar stop showed a focus ring in screenshots; Toggle Sidebar, Import, Edit, Copy, and Save don’t report themselves as the focused element in the accessibility tree, so they were identified from the screenshots. Tab left the Names and Terms field instead of inserting a tab. |
| History by keyboard | **Passed.** With the History list focused, Down Arrow selected the older entry and Up Arrow the newer one; the window title, transcript, and Recording values followed the selection. Delete was not pressed. |
| Keyboard activation | **Passed.** Space on the focused Toggle Sidebar button hid the sidebar and showed it again. ⌘O, ⌘⇧G, a typed path, and Return imported both fixtures. |

A macOS privacy prompt asking whether the terminal could bypass the screen-capture picker appeared during the screenshots and was left for the user to answer. It covered part of the transcript, so the 200% layout was captured at two window positions that together show the whole column. Screenshots are in the ignored `build/accessibility-recheck/` folder. Spoken VoiceOver remains unverified.
