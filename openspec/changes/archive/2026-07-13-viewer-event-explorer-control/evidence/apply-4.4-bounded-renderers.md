# Task 4.4 Bounded Inspector and Renderer Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerEventInspectorModel` retains one selected `ViewerCanonicalEventDetailBuffer`, one exact
  runtime/generation/Event token, and one applied preparation. Selection replacement invalidates the
  prior token; clearing removes the canonical detail and every prepared value. The serial
  `ViewerRendererPreparationService` cancels a superseded generation through bounded checkpoints,
  and stale completion cannot update the model.
- Raw JSON navigation covers the exact canonical bytes in UTF-8-safe chunks of at most 64 KiB. It
  retains one chunk string at a time, exposes previous/next state, and creates only a 512-byte bounded
  focused accessibility value rather than one full accessibility string.
- Pretty JSON accepts at most 1 MiB, derives at most 2 MiB, checks cancellation/work and the strict
  100-ms deadline every bounded scan interval, and otherwise leaves the complete content available
  through chunked raw navigation with fixed guidance.
- The JSON tree stores shared key/value byte ranges, parent identities, bounded previews, and loaded
  expansion offsets rather than copied full values or paths. Each expansion reads at most 128 direct
  children, the state retains at most 4,096 nodes and 2 MiB derived text, previews are at most 256
  bytes, focused accessibility is at most 512 bytes, and expansion is generation-cancellable.
- `ViewerRendererRegistry` is immutable and internal. It resolves the most specific built-in
  `timeline.*`, `table.*`, `chart.*`, or `log.*` pattern before the mandatory `*` Generic JSON
  fallback. It has no mutation API, third-party bundle loading, or performance-dashboard behavior.
- Log preparation accepts one string or one top-level object string `message`, reads at most 4,096
  entries and 1 MiB within 100 ms, retains at most 64 KiB of derived text in at most 4-KiB chunks,
  and caps focused accessibility at 512 bytes.
- Table preparation scans at most 4,096 top-level entries and 1 MiB within 100 ms, retains at most
  128 scalar descriptors backed by exact key/value ranges, pages 64 rows, derives at most 512 KiB,
  caps key/value previews at 256/1,024 bytes, caps focused accessibility at 512 bytes, and reports
  `hasMore` without retaining complete copied values.
- Numeric preparation accepts at most 8 MiB, scans no more than 200 rows within the same 100-ms
  budget, and retains at most eight finite field labels and 200 scalar points. The one-detail model
  owns no numeric content page and this renderer is not the deferred performance dashboard.
- Structured log/table labels are visibly isolated and replace every C0/C1 or bidirectional-format
  scalar with an explicit `<U+XXXX>` token. Incompatible shape, cancellation, input/output/work, or
  deadline exhaustion returns typed fixed Generic/refine guidance and cannot alter query, store, or
  session ownership. Content-bearing reflection exposes only bounded counts or byte counts.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testRendererRegistryPreparesBoundedRawTreeLogTableAndNumericFallbacks -only-testing:NearWireViewerTests/ViewerFoundationTests/testInspectorPreparationCancelsReplacedGenerationAndClearsCanonicalBuffer
```

Result: `TEST SUCCEEDED`; 2 tests executed, 0 failures.

The tests reconstruct a multibyte canonical JSON value from raw chunks, prepare bounded pretty
output, page a 130-child shared-range tree as 128 plus 2 children, exercise log control/bidi escaping
and 64-KiB/4-KiB output limits, retain and page exactly 128 of 130 table scalars, scan 200 of 201
numeric rows while retaining exactly 200 points and at most eight fields, and prove incompatible,
cancelled, exact-deadline, and oversized log inputs fall back to Generic with fixed typed reasons.
They also hold the serial preparation queue, replace the selected generation, prove the first work
is cancelled and rejected as stale, apply only the second result, and clear the sole canonical
buffer. Secret test content remains absent from generic diagnostics.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 216 tests executed, 2 skipped, 0 failures.

The configured-signing application entitlement assertion remains intentionally deferred to the
Goal-level release-hardening verification. This unsigned validation does not claim release-signing
evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerJSONInspection.swift Viewer/NearWireViewer/Application/ViewerRendererRegistry.swift Viewer/NearWireViewer/Application/ViewerEventExplorerModel.swift Viewer/NearWireViewer/Application/ViewerExplorerTimeline.swift Viewer/NearWireViewer/Application/ViewerEventExplorerCoordinator.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
