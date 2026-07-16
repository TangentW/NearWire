# Validation Evidence

## Focused reconnect tests

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-device-row-reuse-focused \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testDeviceRowsCoalesceReconnectHistoryButKeepDifferentAndImportedRoutes \
  -only-testing:NearWireViewerTests/ViewerFlowControlTests/testExactRouteReplacementMigratesSelectionAndShowsFreshEpochEvent
```

Result: passed. The real exact-route replacement test now verifies one Device row, stable
presentation identity, newest connection targeting, and selected-connection migration. The pure
row reducer test covers multiple predecessors, current preference, aggregated warning/materialized
state, most-recent ended fallback, different application routes, and imported rows.

## Relevant Viewer test classes

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-device-row-reuse-final \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerFoundationTests \
  -only-testing:NearWireViewerTests/ViewerFlowControlTests
```

Result bundle:

```text
/tmp/nearwire-device-row-reuse-final/Logs/Test/Test-NearWireViewer-2026.07.17_02-59-47-+0800.xcresult
```

Result: 144 total, 143 passed, 0 failed, 1 skipped. The stable-signer packaging test is expected to
skip without two configured signing identities.

An earlier class run ended before compilation because accumulated temporary DerivedData filled
`/tmp`. Only recent `/tmp/nearwire-*` DerivedData directories were removed; repository files and
normal Xcode DerivedData were untouched. The clean rerun passed.

## Build and specification

The Viewer build passed with ad-hoc signing in `/tmp/nearwire-device-row-reuse-build`. Strict
OpenSpec validation and `git diff --check` passed. OpenSpec's optional PostHog flush could not
resolve `edge.openspec.dev` after successful validation.
