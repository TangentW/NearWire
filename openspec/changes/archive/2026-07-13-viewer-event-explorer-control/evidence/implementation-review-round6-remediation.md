# Implementation Review Round 6 Remediation

Date: 2026-07-14

## Result

All five unique round-6 findings are remediated. The focused regression set passes with nine tests
and zero failures. Complete package, Viewer, production-build, formatting, diff-hygiene, and strict
OpenSpec validation remain to be rerun before a fresh independent review round.

Configured signing and embedded-entitlement verification remains deferred to Goal-level
`release-hardening` by the product-owner decision and is not a finding in this change.

## ARCH-R6-001 / CT-R6-001 — one joined store-shutdown owner

- `ViewerStoreCoordinator.runtimeEnded` now has one asynchronous owner. Concurrent and later callers
  join that owner instead of independently closing SQLite while accepted preparation/ingress work is
  still draining.
- Every storage-close route enters one idempotent close owner in the required order: close
  maintenance, deactivate and join the coalesced status signal, then close the SQLite pool.
- A blocked-provider regression starts two runtime-end callers, proves neither returns while the
  provider is retained, releases it, proves both callers return, proves no stale delivery occurs,
  and proves later publication schedules no work.

## ARCH-R6-002 — callback-safe gateway retirement

- Active operations clear exact query/catalog cancellation state before invoking arbitrary client
  completion and retire their generation/group ownership before the completion runs. Queued
  operations likewise retire cancellation/group ownership before arbitrary rejection.
- Replacement transitions serialize detach/seal/publish independently from the generation-state
  lock. Arbitrary callbacks run only after transition ownership is released, so they may install or
  seal synchronously without self-join or transition-lock deadlock.
- Regressions prove finite active-completion replacement, queued-rejection sealing, and a
  three-coordinator external/callback installation race with one deterministic winner and no
  orphan generation.

## CT-R6-002 — committed export success remains authoritative

- Export remains generically cancellable before start and through the export service's pre-commit
  seal. Those paths report `cancelled` and preserve an existing destination.
- When the export service returns success, atomic destination replacement has already committed.
  Gateway finish therefore preserves that successful candidate across a later generic cancellation
  or coordinator replacement instead of presenting a false cancelled/store-replaced result.
- A completion-boundary regression proves the destination is already replaced, applies
  cancellation, then requires one successful callback, one retired operation, cleared cancellation
  state, and one valid exported Event.

## SPD-R6-001 — atomic controller cancellation/delivery handoff

- Every controller operation owns one lock-protected delivery gate and one work-tracker identity.
  A callback must claim the gate before it creates a MainActor task.
- Cancellation that wins first completes the tracker and makes every later callback return without
  creating a task. If delivery already claimed, cancellation leaves the tracker owned until the one
  MainActor handler calls the idempotent finish path, including stale or sealed results.
- A controller-level 100,000-replacement regression retains at most one active plus one queued
  gateway operation, leaves one current controller tracker before cleanup, creates zero delivery
  claims for all cancelled replacements, and reaches zero work after release.
- A second controller regression blocks immediately after a result claims delivery, seals the
  controller, proves cleanup remains pending with one tracked item, releases delivery, and proves
  cleanup and the gateway reach zero only after the MainActor handler discards the sealed result.

## SPD-R6-002 — conflict markers follow exact connection residence

- Conflict-marker removal returns the exact removed count. Direct-to-managed reconciliation,
  normal ended-session reclamation, and terminal capacity eviction all remove every marker for the
  retiring connection and add that count to saturating diagnostic loss.
- The direct-lifecycle evidence wording now states its exact scope instead of implying every managed
  retirement path was already covered in round 5.
- Regressions cover direct reconciliation, ordinary managed reclamation after `journalConflict`,
  and terminal capacity eviction while another Event keeps the ended session resident. Each ends
  with zero detached markers and exact overflow/diagnostic counters.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testLifecycleTransitionClearsDetachedDirectConflictMarker \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testManagedSessionReclamationRemovesDetachedConflictMarker \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testManagedSessionCapacityEvictionRemovesDetachedConflictMarker \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testConcurrentRuntimeEndPathsJoinBlockedStatusProviderBeforeStorageClose \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayActiveCompletionCanInstallReplacementReentrantly \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayQueuedRejectionCanSealReentrantlyWhileActiveWorkFinishes \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testGatewayCancellationAfterCommittedExportPreservesSuccessAndClearsState \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testControllerHundredThousandReplacementsCancelBeforeSchedulingDelivery \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testControllerCleanupJoinsResultWhoseDeliveryWasAlreadyClaimed
```

Exact result:

```text
Executed 9 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_01-33-09-+0800.xcresult
```

## Complete validation

Complete unsigned Viewer suite:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
Executed 261 tests, with 2 tests skipped and 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

The two skipped tests are the configured-signing/embedded-entitlement gate deferred to Goal-level
`release-hardening` and the explicit machine-local live-container audit that requires its opt-in
marker. Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_01-34-01-+0800.xcresult
```

Root package suite:

```text
swift test
Executed 537 tests, with 0 failures (0 unexpected)
```

The first sandboxed invocation could not write Swift/Clang user module caches and failed before
manifest loading. The unchanged command passed with standard compiler-cache access; no validation
was weakened and no shell harness was added.

Unsigned production build:

```text
xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **
```

Static gates:

```text
swift package dump-package
exit 0

plutil -lint Viewer/NearWireViewer/Resources/Info.plist \
  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy \
  Viewer/NearWireViewer/Resources/NearWireViewer.entitlements
all files: OK

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
exit 0
```

The sandboxed `swift package dump-package` invocation encountered the same compiler-cache denial;
the unchanged command passed with standard cache access and confirmed no package dependencies, iOS
16/macOS 13 floors, Swift 5 language mode, and no Viewer source in the root package products.
