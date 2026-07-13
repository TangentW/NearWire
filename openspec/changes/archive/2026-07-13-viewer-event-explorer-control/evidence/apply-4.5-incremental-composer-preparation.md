# Task 4.5 Incremental Input and Composer Preparation Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerIncrementalTextBuffer` applies one validated `NSRange` replacement while maintaining
  cached UTF-8 byte, Unicode-scalar, and UTF-16 counts. It scans only the replacement and removed
  range for metric deltas, rejects invalid ranges, unsupported characters, byte overflow, or scalar
  overflow before mutating stored text, and exposes logical edit/scan/storage-copy counters with a
  structural zero full-value-rescan count.
- `ViewerComposerTextLimits` computes the content editor limit with checked nonnegative arithmetic
  as `min(active content, (min(active model, 16 MiB) - 65,536) / 4)`. Event type also honors the
  active limit up to 128 UTF-8 bytes, and TTL input is capped at nine bytes.
- Search, JSON path, JSON comparison value, recording name, note, and annotation use the same
  incremental coordinator with exact 512-byte, 256-byte, 16-KiB, 80-scalar/120-byte, and
  4,096-scalar/16-KiB limits. Large or multibyte paste follows the ordinary edit path and cannot
  enter model storage when it would exceed a cap.
- `ViewerTTLTextParser` accepts exactly one through nine ASCII digits and a `UInt64` value within
  `1...active maximumTTLMilliseconds`. Empty, signed, whitespace, non-ASCII, and more-than-nine-digit
  input is a syntax failure; zero or an otherwise numeric value outside the active range is a range
  failure.
- `ViewerControlComposerModel` is MainActor-owned and memory-only. Every accepted edit, priority or
  policy change, explicit preparation request, and clear invalidates the prior exact runtime and
  generation token. A stale result cannot restore a prepared Event or validation failure.
- `ViewerComposerPreparationService` owns one replaceable serial off-MainActor preparation token.
  The latest request cancels superseded work at bounded stage checkpoints. Preparation creates one
  input `Data` copy, performs one logical Core JSON preparation/traversal stage, constructs one
  validated user `EventDraft`, encodes it once, and passes the immutable encoded result into
  `ViewerPreparedControlEvent` without target-side re-encoding. Attempt counters are incremented
  before their operation so failed work is not reported as zero work.
- User-entered `nearwire.*` types fail through `EventType.user`. The prepared policy is either normal
  or canonical Event-type keep-latest, and the existing 16-MiB prepared-Event gate remains
  authoritative. All input snapshots, buffers, operator text owners, preparation requests/results,
  outcomes, and the composer model have content-free descriptions and reflection.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testIncrementalTextBuffersEnforceEveryOperatorCapWithoutFullValueRescans -only-testing:NearWireViewerTests/ViewerFoundationTests/testComposerPreparerReportsBoundedFailuresWithoutEncodingInvalidInput -only-testing:NearWireViewerTests/ViewerFoundationTests/testComposerPreparationReplacesOneGenerationAndCountsOneSuccessfulPipeline
```

Result: `TEST SUCCEEDED`; 3 tests executed, 0 failures.

The tests cover multibyte edit-range replacement, byte/scalar boundary rejection with unchanged
storage, zero full-value rescans, the checked 16-MiB content formula, exact TTL syntax/range limits,
all operator editor caps, and content-free reflection. They also cover invalid JSON, reserved type,
invalid TTL, immediate cancellation, a blocked serial queue with two generations, stale-result
rejection, exactly one successful input-copy/traversal/validation/encode count, canonical
keep-latest preparation, and complete composer clearing.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 219 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The
configured-signing application entitlement assertion is the other skip and remains intentionally
deferred to the Goal-level release-hardening verification. This unsigned validation does not claim
release-signing evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerComposerPreparation.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
