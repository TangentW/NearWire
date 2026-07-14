# Validation Evidence

Date: 2026-07-15

## OpenSpec

- `openspec validate fix-viewer-reconnect-live-ui --strict`
- Result: exit 0, `Change 'fix-viewer-reconnect-live-ui' is valid`.
- The command also emitted a non-gating PostHog DNS error for `edge.openspec.dev`; local strict validation completed successfully before that telemetry flush.

## Focused regressions

- Twelve reconnect and live-presentation regressions passed together: five session-manager tests and seven Event Explorer/UI tests, 12 executed, 0 failures.
- Three refresh-failure regressions passed together, 3 executed, 0 failures.
- The partial-success refresh-failure regression and the unrelated storage-settings retry passed together, 2 executed, 0 failures.
- Covered exact-route replacement, failed candidate attachment, displaced cleanup bounds, unique/ambiguous live-to-durable reconciliation, immediate analysis-mode redraw, ordinary refresh retention, inspector reload/clear behavior, single-flight pagination, and minimum-size filter rendering.

## Full Viewer suite

Command:

`xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= test`

Fresh final result:

- `** TEST SUCCEEDED **`
- 409 tests executed.
- 407 passed, 2 explicitly skipped packaging/audit probes, 0 failures.
- XCTest result: `/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.15_04-03-57-+0800.xcresult`.

An immediately preceding full run had one unrelated storage-settings assertion affected by process-wide test state. The exact test passed on isolated retry, and the complete fresh 409-test rerun then passed. No product or test source was weakened for that retry.

The two skipped probes require an explicitly configured stable signer and a machine-local audit marker. Per project direction, signing configuration is not committed and the stable-signer gate remains deferred to final distribution verification.

## Build

Command:

`xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

Result: `** BUILD SUCCEEDED **`.

The Xcode compilation log enabled Swift strict concurrency and Swift 5 language mode for the Viewer target.

## Source hygiene

- `git diff --check`: exit 0.
- Existing local Xcode project and scheme changes were treated as user/signing state and excluded from this change's delivery set.
