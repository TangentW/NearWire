# Task 3.5 Control Capability Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerMultiDeviceSessionManager` issues one memory-only capability for each accepted exact
  connection. The capability combines a random token UUID with the runtime logical ID, manager
  generation, and connection ID. Its members and synthesized initializer are file-private, so the UI
  can retain an issued value but cannot reconstruct one.
- Active capabilities share the existing 16-session bound. Terminal transition atomically removes
  the exact active capability and places it in a separate connection-keyed cache. The cache retains
  at most 64 entries while monotonic elapsed time is strictly less than 30 seconds, expires at
  equality, evicts by oldest terminal time and then token UUID lexical order, and owns a single
  replaceable expiry wake. Shutdown seals control admission, clears active and terminal capabilities,
  cancels the expiry wake, and returns no targets.
- Same-route reconnect creates a new connection and capability without deleting or satisfying the
  old terminal capability. Duplicate connection IDs inside the active/terminal ownership horizon are
  rejected rather than replacing an exact capability.
- `ViewerPreparedControlEvent` validates a checked 1-through-16-MiB deterministic encoded size and
  stores one immutable `EventDraft`, accounted byte count, and precomputed normal or canonical
  Event-type-keyed keep-latest queue policy. Preparation encodes once. Per-target admission constructs
  only the bounded queue item from those values and performs no JSON encoding or content traversal.
- One serialized manager attempt accepts 1 through 16 capabilities, counts token UUIDs first, and
  marks every occurrence of a duplicate token as `invalidTarget`. Unique capabilities preserve input
  order and use O(1) exact active/terminal lookups.
- Wrong runtime/generation, never-owned, expired, evicted, or shutdown-cleared capabilities are
  `invalidTarget`; an exact terminal-cache hit is `noLongerConnected`; a resolved session that is not
  active is `notActive`; active queue refusal is `queueRejected`; and an actual buffered item is
  `queued`. Terminal transition after queue commit does not rewrite the returned result.
- Results contain only input index and typed outcome. Success wording is exactly `Queued locally`.
  Capabilities, prepared drafts, targets, and results provide content-free/redacted diagnostics. No
  retry, route retargeting, cross-target rollback, delivery claim, persistence, or separate history
  was added.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests/testPreparedControlEventEncodesOnceAndClassifiesTargetsAuthoritatively -only-testing:NearWireViewerTests/ViewerFlowControlTests/testPreparedControlEventRejectsInvalidEncodedSizes -only-testing:NearWireViewerTests/ViewerFlowControlTests/testSameRouteReconnectKeepsOldTerminalCapabilityIndependent -only-testing:NearWireViewerTests/ViewerFlowControlTests/testRecentRowsAreCappedAndExpireAtExactThirtySecondBoundary
```

Result: `TEST SUCCEEDED`; 4 tests executed, 0 failures.

The focused tests prove one encode across admissions, exact local success wording, ordered results,
all-occurrence duplicate rejection, wrong runtime/generation rejection, active queue rejection, 0 and
17 target rejection, shutdown clearing, redacted diagnostics, invalid encoded-size boundaries,
negotiating-session classification, same-route reconnect independence, deterministic 65th-entry
terminal-cache eviction, physical 64-entry bound, retention immediately before 30 seconds, and
expiration at exact equality.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 210 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate. The other is the opt-in Application Support artifact
audit that requires its machine-local marker.

After the strict formatter removed an unnecessary explicit memberwise initializer, the affected
production code was rebuilt and the principal capability test passed again.

## Static and specification validation

- `xcrun swift-format lint --strict` passed for all production and test files affected by task 3.5.
- `git diff --check` passed.
- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  reported `Change 'viewer-event-explorer-control' is valid`.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64`; this evidence does not claim configured signing passed.
