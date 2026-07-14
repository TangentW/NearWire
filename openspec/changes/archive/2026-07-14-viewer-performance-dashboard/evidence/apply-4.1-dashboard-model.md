# Apply 4.1 Evidence: Single-Device Dashboard Model

Date: 2026-07-14

## Implemented behavior

- One `@MainActor` observable dashboard model owns exactly one current connection or historical
  device-session source, one source generation, and one fixed range. The type cannot represent a
  multi-device overlay.
- Scope replacement clears all prior cards, buckets, availability, gaps, invalid details,
  crosshair, progress, and freshness identities before publishing the successor idle state.
- Projection delivery validates exact source, generation, range, complete bucket bounds, contiguous
  bucket geometry, and current-versus-historical clock-domain receipt before mutating presentation.
- Current presentation retains only the current absolute-deadline receipt. Historical presentation
  retains only the same-recording frozen-upper receipt, requires complete-range coverage, and owns no
  current deadline.
- Exact current expiry restates cards as No recent sample without changing chart buckets. A stale
  Event/deadline/revision receipt cannot mutate presentation, and diagnostics stop reporting an
  armable deadline after expiry while retaining the receipt for predecessor rejection.
- Six fixed chart groups cover all ten numeric metrics exactly once: display, CPU, memory, battery,
  throughput, and queue/drop.
- Progress, explicit ready/empty/live-only/storage-unavailable/error phases, all 16 availability
  entries, bounded gaps/invalid details, and one synchronized crosshair are exposed to the future
  SwiftUI surface.
- The model, exact scope, and crosshair use content-free reflection. Diagnostics expose only fixed
  phase and bounded counts, never source identity or received values.

## Focused and integration test command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-1-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests
```

Result:

```text
Executed 15 tests, with 0 failures (0 unexpected) in 0.144 (0.152) seconds
** TEST SUCCEEDED **
```

Coverage includes exact current and historical scopes, current/historical receipt exclusivity,
six-group inventory completeness, progress and error states, live-only and empty coverage, source/
generation/range rejection, expiry identity/revision matching, immutable charts at expiry,
synchronized crosshair bounds, scope clearing, sealing, and content-free reflection.

## Unsigned build

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-1-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

Result:

```text
** BUILD SUCCEEDED **
```

This unsigned build intentionally does not claim signed embedded entitlement or stable-signer
validation. Those externally configured checks remain deferred to the Goal-level
`release-hardening` change.

## Static gates

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceDashboardModel.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Package.swift NearWire.podspec Viewer/NearWireViewer/Store/ViewerStoreSchema.swift
exit 0; no output
```
