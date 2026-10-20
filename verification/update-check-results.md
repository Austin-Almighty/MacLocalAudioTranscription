# App update checks

Verified October 20, 2026, on this Apple Silicon Mac:

- All six `AppUpdaterTests` passed in an isolated Swift package using the app’s actual update source file. Coverage includes numeric version ordering, invalid versions, drafts/prereleases/unpublished releases, unofficial download links, missing/malformed assets, and HTTP errors.
- All app sources passed Swift 6 type checking. An optimized macOS 15+ arm64 executable linked successfully against the existing Release SDK objects and was installed in `dist/LocalTranscription.app`. Its ad hoc signature passes strict verification.
- The rebuilt app launched. Its app menu contains “Check for Updates…”. A real request to the configured GitHub repository displayed “No official release is available yet.” Dismissing the alert returned to the normal app interface.
- `Scripts/package-release.sh` ran successfully. The ZIP contains the rebuilt app, and its SHA-256 matches the generated `Casks/local-transcription.rb`. The cask passes Ruby syntax validation and declares Apple Silicon and macOS 15+ requirements.
- The uploaded source tree matched the local staged Git tree exactly: `b9482ee01008ac4a9c13915e6f74f837dc2f9ef0`.

The full Xcode regression run could not execute within this session: package caches are restricted, and the isolated-cache retry could not resolve the cached package products. Existing transcription tests were not rerun. The new update tests ran independently without model downloads or external network access.

A newer-release download, Homebrew installation/upgrade, and iOS device behavior remain unverified. There is no official release yet. The generated cask remains local until its exact ZIP has been published; only the packaging script is on GitHub. Developer ID signing and notarization remain necessary for the intended public distribution workflow.

Terminal SSH could not resolve github.com in this session. Source was uploaded through the authenticated GitHub connector. Temporary Git metadata and the SSH origin are in `build/publish.git`; this session cannot create the project’s protected `.git` directory. A normal SSH clone of the published repository can be used for subsequent development outside this restricted session.
