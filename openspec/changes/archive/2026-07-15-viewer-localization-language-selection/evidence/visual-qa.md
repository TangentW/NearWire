# Visual QA

The Viewer was built as an isolated ad-hoc QA application with bundle identifier `com.nearwire.viewer.localizationqa` so other running NearWire builds and their preferences could not affect inspection.

Observed behavior:

- System mode on macOS `zh-Hans-HK` presented the main Viewer in Simplified Chinese, including programmatic accessibility labels.
- Manual English immediately updated the main Event window, Performance window, and Settings without restarting the process.
- Returning to System immediately updated the already-open Performance and main windows to Simplified Chinese.
- Settings clearly exposes `System`, `English`, and `简体中文` and explains that every Chinese macOS language uses Simplified Chinese while other languages use English.
- Main, Performance, Settings, filter, and composer layouts showed no user-impacting clipping or mixed-language issue at the inspected supported sizes.
- Product and protocol names such as NearWire, Viewer, App, JSON, TLS, Bonjour, and TTL intentionally remain recognizable technical terms.

Saved screenshots:

- `main-simplified-chinese.jpeg`
- `performance-english.jpeg`
- `settings-english.jpeg`

The isolated ad-hoc build can show the expected identity-recovery state because stable Keychain identity continuity requires the maintained signer; that state is unrelated to localization and was not used as a release-signing result.
