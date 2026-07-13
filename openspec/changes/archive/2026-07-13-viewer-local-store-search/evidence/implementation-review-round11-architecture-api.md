# Implementation Review Round 11 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, 0 Low.**

Both Round 10 findings are resolved in their reported paths. The coordinator now retains one bounded initial-outage marker when its accepted runtime-start operation fails asynchronously, and the same-coordinator recovery regression now waits for an exact preparation-prefix boundary before testing recovery admission and completion. One adjacent lifecycle gap remains: a runtime that starts while no coordinator exists, or while the coordinator still belongs to a prior runtime, has the same known nondurable interval but records no marker when there are zero later journal callbacks. A successful reopen can therefore create a partial recording with no required `storageUnavailable` gap.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. This review records neither a finding nor a pass for that deferred work.

## Scope and Evidence Basis

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the complete current production, test, packaging, operator-documentation, and evidence change; all three Round 10 implementation-review reports; `implementation-remediation-round10.md`; and `implementation-validation-round11.md`. It retraced the Round 10 findings plus prior writer-first bootstrap, maintenance quiescence, generation-bound recovery, runtime replacement, settings supersession, terminal flush, and callback-diagnostic remediations. It also rechecked preparation/ingress ownership, lock and executor order, callback retention, public/internal API exposure, and Core/SDK/Viewer placement.

Fresh current-tree validation performed by this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
# exit 1; no matches

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
# exit 0; no nested manifest or podspec
```

The complete current Store suite also passed independently:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound11ArchitectureReviewDerived \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound11ArchitectureModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireRound11ArchitectureModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests

Executed 79 tests, with 1 test skipped and 0 failures
** TEST SUCCEEDED **
/tmp/NearWireViewerRound11ArchitectureReviewDerived/Logs/Test/Test-NearWireViewer-2026.07.13_12-53-52-+0800.xcresult
```

The one skip is the explicit opt-in live Application Support audit and is not represented as a pass.

## Round 10 Finding Disposition

- **`NW-LSS-IMPL-R10-CT-001` — resolved in the reported accepted-start path.** `ViewerStoreCoordinator.runtimeStarted` catches asynchronous initial recording-admission failure and records one saturating coordinator-local unavailable observation at the runtime start time (`ViewerStoreCoordinator.swift:240-257`). Failed explicit recovery leaves that marker intact. The first successful `ensureRecording(partial: true)` moves it into bounded recording-level gap ownership and clears the local aggregate only after that ownership exists (`ViewerStoreCoordinator.swift:860-890`, `948-973`). `testDirectMaterializationFailureAndFailedRetryCannotReopenIngress` proves an accepted failed start, one failed retry, one later successful retry, one partial recording, one recording-level gap with count one, no invented device, and no duplicate marker (`ViewerStoreTests.swift:3921-4012`). The finding below covers startup paths that never invoke this coordinator-local failure edge.
- **`NW-ISPD10-001` — resolved.** `ViewerJournalPreparationQueue.afterCurrentPrefix` submits one callback to the same serial preparation queue behind its active drain (`ViewerStoreCoordinator.swift:1180-1266`). In the regression, all 40 lifecycle offers occur before the callback is submitted; after the blocked initial operation is released, the drain completes every accepted lifecycle item and their lifecycle reservations before the callback runs. The test then separately blocks the recovery writer turn, proves `isRecoveryInFlight`, releases the injected failure, and verifies the failed claim is restored before the next retry (`ViewerStoreTests.swift:1190-1252`). The exact final recording-level unavailable count is six: one coordinator-local failed-start marker plus five lifecycle offers rejected by the 36-slot lane; one still-live device is materialized once.

## Finding

### NW-LSS-IMPL-R11-ARCH-001 — Medium — Zero-observation runtime startup without a coordinator can recover without the required unavailable gap

The new initial-outage marker belongs only to an already-created `ViewerStoreCoordinator`. `ViewerStoreRuntime` can also begin a logical runtime with no coordinator because store path/bootstrap/schema creation failed. Its initializer leaves `coordinator` nil (`ViewerStoreCoordinator.swift:1321-1338`). `runtimeStarted` stores the logical context but resets `missedObservationCount` to zero. When `coordinator` is nil, it does not add an initial marker before returning; likewise, when the current coordinator still belongs to a prior runtime, it marks recovery necessary but adds no missed observation (`ViewerStoreCoordinator.swift:1443-1495`).

On a later explicit retry, `attemptReopen` installs a fresh coordinator, begins a recovery claim from the still-zero `missedObservationCount`, and calls `recoverRuntimeAndSessions` with zero missed observations and no sessions (`ViewerStoreCoordinator.swift:1773-1833`, `1842-1851`). The fresh coordinator never executed the failed `runtimeStarted` operation, so its new local unavailable aggregate is also zero. `recoverRuntimeAndSessions` creates the partial recording but records a recording-level gap only when `missedObservationCount > 0` (`ViewerStoreCoordinator.swift:337-383`). The recovery then completes successfully and publishes available state with no `storageUnavailable` gap.

This violates the active requirement that storage-unavailable startup followed by a successful same-runtime retry materialize the original identity/time **and one coalesced unavailable gap**, even when no device is still live (`specs/viewer-local-store-search/spec.md:29-58`; `design.md:48-52`). It also affects the documented replacement-window path: a new runtime held nondurable while the old coordinator finishes can recover with no gap if it produces no intervening callback (`design.md:169-179`; `Documentation/Viewer-Local-Store.md:29-33`).

The current tests mask both zero-observation paths. `testUnavailableRuntimeReopensAfterExplicitRetry` deliberately calls `policyChanged` while the coordinator is absent, which raises the runtime missed count to one before reopen (`ViewerStoreTests.swift:1065-1119`). `testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime` similarly sends a callback for the replacement runtime before old-runtime cleanup completes (`ViewerStoreTests.swift:1254-1300`). Neither test starts nondurably, emits no journal callback, repairs/releases ownership, retries, and asserts one gap.

Required resolution:

1. Give `ViewerStoreRuntime` one generation-bound bounded initial-outage marker whenever a logical runtime starts without an attachable coordinator, including bootstrap failure and prior-runtime coordinator ownership. Do not rely on a later Event/session/policy callback to manufacture the required gap.
2. Move that marker into the exact recovery claim, retain it across reopen/admission/materialization failure, and consume it only after the replacement coordinator owns one recording-level `storageUnavailable` gap. Preserve saturation and late-callback identity guards, and do not duplicate the coordinator-local marker when an accepted start itself fails.
3. Add deterministic zero-observation regressions for unavailable bootstrap and replacement-runtime handoff. Each should prove a failed retry retains the marker, the first successful retry creates the original partial recording plus exactly one recording-level gap and no device, and a later retry does not duplicate it.

## `afterCurrentPrefix` Architecture/API Audit

- Ordering is sufficient for the current lifecycle regression. The callback is enqueued on the preparation serial queue behind the active drain, so it cannot overtake any item accepted before the call. Operations accepted later may also finish before it if the active drain observes them; the seam promises a lower-bound prefix, not a suffix boundary.
- The callback executes after the tested lifecycle item closures return and their lifecycle reservations deinitialize. It does not claim writer/ingress durability. Event observations may transfer their reservation to ingress, so this seam must not be treated as a whole-pipeline flush; the current test uses lifecycle-only items and does not make that broader claim.
- The seam adds no Event/structural reservation and stores no callback in a collection. Its one current caller retains only an XCTest expectation until the serial queue reaches it. It introduces no polling, semaphore wait on the preparation executor, lock inversion, or production retry loop.
- `afterCurrentPrefix`, `afterCurrentPreparationPrefix`, and `afterCurrentJournalPrefix` are Viewer-module-internal and absent from `ViewerSessionJournaling`, Core, SDK, the root package products, and CocoaPods. Repository search finds no production caller; the only caller is the focused Viewer test.

## Whole-Change Architecture and Boundary Recheck

- Writer-first migration and schema acceptance still precede both read connections; construction failure unwinds local connection ownership without publishing a partial pool.
- Writer failure publication still advances the authoritative relay generation before releasing the writer turn. Recovery claims, coordinator/runtime identities, settings revisions, and maintenance permits reject obsolete completion.
- Runtime end invalidates maintenance work, reaches the maintenance serial barrier, then performs one terminal preparation finish and finite ingress flush before pool close. No new prefix callback participates in production shutdown or replacement ownership.
- Session/protocol ownership remains outside persistence. Journal callbacks cannot mutate wire sequence, queues, tokens, mailbox state, timeout, or terminal arbitration.
- SQLite, query, export, maintenance, coordinator, preferences, and their test seam remain Viewer-only and module-internal. Core remains platform-neutral, SDK production code remains unchanged, and no SDK persistence/search API or third-party Core/SDK dependency was introduced.
- The manually maintained Viewer project continues to link only system SQLite plus Apple frameworks and the root local package. Swift 5 language mode, iOS 16 SDK support, and macOS 13 Viewer compatibility remain intact. Current UI and product exclusions remain unchanged.

## Approval Gate

Architecture/API approval requires resolving `NW-LSS-IMPL-R11-ARCH-001`, adding zero-observation bootstrap and replacement coverage, saving fresh affected and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved actionable findings**. Configured signing, entitlement assertions, and stable-signer validation remain deferred exclusively to `release-hardening` and are outside this finding count.
