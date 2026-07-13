# Task 6.9 Aggregate Validation

Date: 2026-07-13
Last updated: 2026-07-14 after implementation-review round-12 remediation

## Result

The unsigned Viewer production build, complete Viewer test suite, affected root package suite,
formatting, package-boundary inspection, privacy/resource inspection, and strict OpenSpec validation
pass on this Apple-silicon host. Structural tests gate the normative limits; reported wall-clock and
whole-process memory measurements are diagnostic machine context only.

Configured distribution signing and validation of the entitlements embedded in a signed product are
intentionally deferred to the Goal-level `release-hardening` change. This task does not claim that the
deferred signing gate passed.

## Production build and complete test suites

Viewer production build:

```text
xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **
```

Complete Viewer suite:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
** TEST SUCCEEDED **
totalTestCount: 276
passedTests: 274
skippedTests: 2
failedTests: 0
expectedFailures: 0
```

The result summary was read from:

```text
/tmp/NearWire-Round11-FinalPoolOwnership.xcresult
```

The two configured-machine gates are not treated as product evidence in this unsigned run: the
running-application entitlement assertion is command-skipped, and the live Application Support
artifact audit self-skips without its explicit machine-local opt-in marker. Configured signing
remains final release-hardening work; the local-container audit is intentionally opt-in.

Affected root package suite:

```text
swift test
Executed 537 tests, with 0 failures
```

The sandboxed first invocation could not write the user Clang module cache. The unchanged command
passed with standard compiler-cache access. No test or validation gate was weakened.

## Large migration structural and diagnostic gates

The most recently recorded diagnostic values for the two populated schema-1 migration tests were:

```text
testLargeVersionOneMigrationBoundsResourcesAndLeavesOnlyKeySorters
  heap-growth=21217328
  database-high-water=26894336
  wal-high-water=0
  temp-high-water=0
  samples=6

testLargeVersionOneMigrationCancelsWithinInjectedProgressDeadline
  acknowledgement-ns=233083
  heap-growth=245760
  database-high-water=26894336
  wal-high-water=0
  temp-high-water=0
  samples=2

Executed 2 tests, with 0 failures
```

The fixture contains 100,000 Events and 10,000 gaps. Assertions, rather than the diagnostic output,
gate heap growth at no more than 128 MiB, injected cancellation acknowledgement at no more than
250 ms, the 10,000-VM-instruction progress cadence, one migration transaction, the exact three added
indexes, accepted final query plans, rollback and retry behavior, safe temporary storage, and zero
remaining sorter descriptors. The database/WAL/temp sizes and elapsed values above are host context,
not portable product guarantees. Full migration/query evidence is in
`test-6.1-migration-query-races.md`.

## 100,000 live-offer gate

`testHundredThousandLiveOffersUseOneBoundedDrainAndRefreshWake` prefills the 512-row live window,
blocks the projection executor, and offers 100,000 observations. Its exact asserted outcomes are:

```text
ingress offers                    100000
accepted                              1
deferred                             63
untracked                         99936
drain schedules                       1
dirty-successor marks                 1
drain runs                            1
maximum concurrent drains             1
snapshot publications                 1
refresh schedules                     1
refresh deliveries before wake        0
refresh deliveries after wake         1
retained rows                        512
ingress-gap count                  99936
window-overflow count                  1
```

The test also asserts the exact retained deterministic byte accounting. One focused execution printed
`callback-total-ns=56057459` and `process-footprint-growth=16384`; those two values are diagnostic
machine context only and are not latency or memory guarantees.

## Sustained status, gateway, and authority gates

`testChangeSignalCoalescesSnapshotProviderBeforeWorkAndJoinsDeactivation` blocks the snapshot provider,
publishes 100,000 changes, and directly asserts one running provider plus one dirty successor, exactly
two provider invocations and deliveries total, at most 32 changed recording IDs, joined cleanup, and
zero post-deactivation delivery.

`testQueuedGatewayCancellationRemainsBoundedAcrossHundredThousandReplacements` blocks one active
gateway request, fills the hard 16-operation bound, proves request 17 is `busy`, cancels all 15 queued
requests, and then submits/cancels 100,000 replacements. It directly asserts one retained active
operation, zero pending operations, 100,000 exact cancellation completions, and zero retained work
after the predecessor finishes.

`testDuplicateSessionChurnReleasesOwnerlessAuthorityAcrossCapacityHorizon` crosses the 576-entry
authority horizon with 600 blocked replacement generations. It directly asserts every fresh Event is
accepted, ownerless authority remains zero, final authority and live Event counts are both one, and the
two disclosed losses per generation total exactly 1,200.

Round-6 lifecycle/cancellation regressions additionally prove that two runtime-end callers join one
blocked status provider before SQLite closes; active and queued client callbacks can reenter
replacement/sealing without deadlock; cancellation after an atomic export commit preserves one
successful result; 100,000 controller replacements schedule zero cancelled-result deliveries; one
already-claimed delivery keeps cleanup pending until its MainActor handler runs; and all direct,
managed-reclamation, and terminal-capacity connection retirement paths remove detached conflict
markers with exact diagnostic accounting. The focused set executes nine tests with zero failures;
`implementation-review-round6-remediation.md` contains the exact command and result bundle.

Round-7 regressions additionally prove linearizable three-coordinator gateway replacement with no
orphan generation; 100,000 blocked renderer replacements and 100,000 composer supersessions each
retain one request and create zero cancelled-result delivery claims; and content-bearing renderer
and composer successes remain joined after delivery claim until MainActor discard. The focused
gateway and delivery sets execute nine tests total with zero failures;
`implementation-review-round7-remediation.md` contains the exact result bundles.

Round-8 regressions additionally prove that 256 result claims while the MainActor is synchronously
blocked retain at most one processing plus one pending value for both renderer and composer,
including maximum legal content; predecessor Store generations cannot publish a catalog after
replacement even when client delivery was already claimed; a delayed native save-panel response
cannot mutate, export, or retain a sealed explorer; and the affected SQLite test closes every pool
before temporary-directory removal. The combined focused set passes nine tests, and the SQLite case
passes ten isolated iterations with no libsqlite API-violation diagnostic. The fresh complete Viewer
suite also contains no such diagnostic. `implementation-review-round8-remediation.md` contains the
exact commands and result bundles.

Round-9 regressions additionally prove that release/query/page/gap traversal stages retain their
exact predecessor Store-generation identity and cannot retarget a replacement generation; an
explicit fresh traversal still succeeds. Commit-aware controller tests prove pre-commit cancellation
preserves the old destination while post-commit user cancellation and Store replacement both publish
the authoritative completed export. The focused set passes 13 tests. Round-9 validation also
corrected three test-fixture pool ownership paths, and their combined 30-run repetition is clean.
`implementation-review-round9-remediation.md` contains the exact tests, commands, and result bundles.

Round-10 regressions additionally prove that a successor synchronously rejected after predecessor
validation returns a delivery-invalid token, publishes no stale error, and creates no replacement
operation. Page and gap rejection now use independent nonempty sentinels, so either guard's removal
fails deterministically. The remaining recording-catalog fixture closes its pool before temporary
directory cleanup. The affected set passes 40 executions, and its complete Viewer suite passes 276
tests with two configured skips and zero failures. Subsequent round-11 raw-log review found further
temporary-pool ownership defects despite the green XCTest summary.
`implementation-review-round10-remediation.md` contains the exact commands and result bundles.

Round-11 remediation first gives all 19 directly affected temporary-pool fixtures deterministic
scope-bound close ownership, then widens the audit to every retained named construction. The 72
retained named `ViewerSQLitePool` constructor sites comprise 70 defer-eligible sites with an
immediate matching defer close and two sequencing fixtures that close explicitly before reopen or
fault injection, with zero static-audit omissions. The original 30-execution reproduction and the
final complete 276-test Viewer suite pass. Exported focused and complete `.xcresult` diagnostics
both have zero matches for
`BUG IN CLIENT OF libsqlite3`, `API violation`, `vnode unlinked`, and
`invalidated open fd`. The final complete result is
`/tmp/NearWire-Round11-FinalPoolOwnership.xcresult`, and its diagnostics are in
`/tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics`.
`implementation-review-round11-remediation.md` contains the exact commands, paths, counts, and
zero-match gates.

## Normative structural coverage map

| Area | Saved structural evidence |
| --- | --- |
| Schema, indexes, plans, VM work, transactions, cursors, leases, generation replacement | `test-6.1-migration-query-races.md` |
| Catalog, timeline, gaps, causality, frozen bounds, paging and cursor restart | `test-6.2-catalog-timeline-diagnostics.md` |
| Shared observation, duplicate horizon, live ingress/window/accounting/wakes | `test-6.3-shared-observation-live.md` and the 100,000-offer gate above |
| Composer caps, encode/copy counts, target tokens, terminal cache, clipboard/privacy behavior | `test-6.4-control-composer-privacy.md` |
| Presentation generations, 100,000 change tokens, renderer rows/pages/nodes/bytes, accessibility caps | `test-6.5-presentation-renderers.md` |
| History revisions, cleanup protection, filtered/complete export transaction and cancellation | `test-6.6-history-export-integration.md` |
| Joined shutdown/replacement cleanup, exact lease release, zero retained content/derived buffers | `test-6.7-blocked-cleanup.md` |

These tests assert the named count, byte, generation, token, VM, page, cursor, wake, and lease limits
directly. Timing is gated only where the specification defines a logical deadline, with injected clocks
or deterministic operation checkpoints wherever possible.

## Test synchronization and ownership corrections found during validation

The following test-fixture issues were corrected without changing product behavior:

1. The blocked cleanup matrix used 1970 timestamps, allowing startup TTL cleanup to delete its own
   fixture. Current timestamps now keep the fixture live; the focused case passed ten repetitions.
2. `testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt` observed the runtime's
   available state before asynchronous recovery had persisted its storage-unavailable gap. Its wait now
   includes the exact gap-count postcondition. The focused case passed twenty repetitions.
3. The round-4 direct-to-lifecycle transition initially reconciled only against active sessions. When
   the first lifecycle callback was `sessionEnded`, it deleted that exact direct-observation session
   and Event before applying the retained termination. Reconciliation now preserves both active and
   same-drain explicitly terminating connections. The original failing regression, adjacent lifecycle
   regressions, and a fresh complete Viewer suite pass without widening any bound or assertion.
4. Moving status snapshot work after coalescing removed an accidental synchronous delay from runtime
   recovery. Four tests waited for available state and an active recording, then immediately asserted
   the later asynchronous storage-unavailable gap. Their waits now include that exact durable gap
   postcondition. The focused cases and a fresh complete suite pass without weakening the expected
   state, recording, or gap assertions.
5. Three passing store tests allowed temporary-directory cleanup to race pool ownership. Two now
   close their pools with scope-bound cleanup; the capacity-recovery fixture also clears its
   store-to-maintenance callback cycle before closing. Thirty combined repetitions pass without a
   libsqlite API-violation diagnostic.
6. Round-10 independent review found the recording-catalog fixture had the same pool-ownership
   mistake. It now closes the pool with scope-bound cleanup, and ten isolated iterations are clean.
7. Round-11 raw-result inspection found 19 more methods relied on ARC to destroy direct temporary
   pools before XCTest teardown. The audit was then generalized to all 72 retained named pool
   constructor sites: 70 defer-eligible sites have an immediate matching defer close, and the two
   sequencing fixtures close explicitly before later throwing work. The original 30-run
   reproduction and final complete Viewer suite pass, and exported raw diagnostics contain zero
   SQLite API-violation matches.

## Project, package, resource, privacy, and static inspection

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
```

`swift package dump-package` passed and confirms:

- no package dependency;
- iOS 16 and macOS 13 platform floors;
- Swift language mode 5;
- only the `NearWire`, `NearWireUI`, `NearWirePerformance`, and `NearWireCore` products;
- Core/SDK source paths only, with no Viewer source or dependency.

Viewer project inspection confirms macOS 13, Swift 5, complete strict concurrency, the expected Info
plist and entitlement source paths, `com.nearwire.viewer`, one root local-package reference, no remote
package reference, and no shell-script build phase. The root Package manifest and podspec contain no
Viewer reference.

`plutil -lint` passes for the source Info plist, privacy manifest, and entitlement plist, and for the
Info/privacy resources copied into the unsigned app. The source declarations include local-network
usage and `_nearwire._tcp`, no probe text, tracking disabled, Device ID used for App Functionality but
not tracking, and the UserDefaults required-reason category. The source entitlement file declares the
App Sandbox plus inbound network server capability. Embedded signed-entitlement validation is the
deferred release-hardening gate described above.

No shell validation harness was added.
