# Validation Evidence

Validated on 2026-07-15 with Xcode 26.5 while compiling distributed sources in Swift 5 language mode. Command-line signing overrides used the local development identity only; no signing configuration is part of this change.

## OpenSpec and source checks

- `openspec validate simplify-viewer-single-session-workspace --strict`
  - Result: passed. The CLI subsequently reported only an optional PostHog DNS failure while flushing telemetry.
- `git diff --check`
  - Result: passed with no whitespace errors.
- `openspec validate --all --strict` after archive
  - Result: all 33 repository specifications passed with 0 failures.

## Viewer

- `xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-viewer-single-session-final-6 DEVELOPMENT_TEAM=9PA6Z533LV CODE_SIGN_STYLE=Automatic test`
  - Result: passed.
  - Tests: 437 executed, 2 existing environment-dependent packaging probes skipped, 0 failures.
  - Duration: 44.681 seconds of test execution; 51.962 seconds total test operation.
  - Result bundle: `/tmp/nearwire-viewer-single-session-final-6/Logs/Test/Test-NearWireViewer-2026.07.15_15-01-33-+0800.xcresult`.
  - The project enables Strict Concurrency and warnings as errors for the Viewer target.

## Root package

- `swift test`
  - Result: passed after granting SwiftPM access to its normal user cache directories.
  - Tests: 546 executed, 0 failures in 2.692 seconds.

## Demo

- `xcodebuild -project Demo/NearWireDemo.xcodeproj -scheme NearWireDemo -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/nearwire-demo-single-session-final CODE_SIGNING_ALLOWED=NO build`
  - Result: passed for arm64 and x86_64 iOS Simulator slices.
  - The Demo compiled with Strict Concurrency and warnings as errors.

## Focused UI and publication checks

- The legacy schema-version-1 disclosure compatibility test passed independently and in the final full suite. Its focused result bundle is `/tmp/nearwire-viewer-legacy-disclosure/Logs/Test/Test-NearWireViewer-2026.07.15_14-46-51-+0800.xcresult`.
- Final focused coverage also passed for schema-version-2 migration, imported and reopened diagnostic-Gap sequencing, ingress work-limit draining, second-pass import cancellation, incremental export byte budgeting, and dedicated import-capacity guidance.
- The final layout-focused run passed at `/tmp/nearwire-viewer-layout-fix/Logs/Test/Test-NearWireViewer-2026.07.15_15-00-11-+0800.xcresult`; it asserts that Analysis retains its minimum height, Timeline stays contained within Analysis, Composer remains inside its bounded viewport and the host window, and neither Analysis nor Timeline intersects Composer.
- The same light/dark, minimum/standard/wide render test passed in the final full Viewer suite and retained six image attachments in its result bundle.
- Filter presentation ignored Timeline-only publications and published exactly once for one filter mutation.
- Timeline-only mutation did not publish Inspector presentation.
- Workspace mutation state was immediate, exclusive, cancellable, and covered by a focused controller test.
