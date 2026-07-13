# Implementation Review Round 4 — Correctness and Testing

Date: 2026-07-13

## Scope and validation basis

This fresh independent review examined the complete current `viewer-local-store-search` working tree after Round 3 remediation. It reread `AGENTS.md`, the active proposal, design, both capability specifications, task plan, current production/test/operator-documentation source, current evidence, the Round 3 correctness report, and `implementation-remediation-round3.md`. The review retraced lifecycle and late-generation cleanup, same-coordinator retry, device identity, preparation/ingress ownership, immutable Event/disposition/gap semantics, exact quota and disk admission, cleanup/reclaim, query compiler and frozen traversal, export lease/cancellation/commit behavior, failure injection, and current evidence.

No production, test, specification, task, or operator-documentation source was modified. Configured-signing, entitlement, and stable-signer tests are explicitly deferred by the user to goal-level `release-hardening` and are not findings here.

Fresh local validation on the reviewed tree:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# no output; exit 0

xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests
Test Suite 'ViewerStoreTests' passed.
Executed 44 tests, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

The current saved Round 4 evidence additionally records 121 unsigned Viewer tests and 531 root Swift package tests passing, plus current packaging, SQLite, privacy, resource, and filesystem inspections. Those results do not exercise the four paths identified below.

## Round 3 finding dispositions

- **NW-LSS-IMPL-R3-CT-001:** the reported Event-plus-initial-disposition underprojection and duplicate Event quota behavior are resolved. `ViewerEventStore` now plans Event and structural net-new quota on its writer executor, and the named regression reaches the prior boundary. The broader remediation statement that every metadata/annotation path uses the same authoritative plan remains incomplete through Round 4 finding 2, and invalid structural plans can still cause cleanup before validation through finding 3.
- **NW-LSS-IMPL-R3-CT-002:** the reported generic Event-type validation and non-ASCII JSON array-index acceptance are resolved in their named forms. Exact types use the 128-byte ASCII segment grammar and JSON indexes use ASCII digits. One impossible maximum-length trailing-dot prefix remains accepted through Round 4 finding 4.
- Generation-bound prior-runtime cleanup, type-strict JSON equality, duplicate peer Event UUID terminal ownership, append-only frozen gaps, disposition-aware reclaim, frozen query/export membership, export lease validation inside the cancellation commit seal, and file commit/cancellation behavior were rechecked and have no retained Round 3 correctness finding.

## Findings

### NW-LSS-IMPL-R4-CT-001 — High — Same-coordinator recovery duplicates already durable live device sessions

`ViewerStoreRuntime.retryStorage` snapshots **all** active sessions and, whenever its global `coordinatorNeedsRecovery` flag is set, offers `recoverSession` for every one after the coordinator retry (`ViewerStoreCoordinator.swift:1463-1499`). That flag may be set by one failed lifecycle offer while other active sessions are already durable. `ViewerStoreCoordinator.recoverSession` unconditionally calls `materializeSession` (`ViewerStoreCoordinator.swift:287-299`); `materializeSession` always creates a new `DeviceSessions` row with a new default UUID and next connection ordinal, then overwrites `devices[connectionID]` (`ViewerStoreCoordinator.swift:761-780`). It neither returns the existing `DeviceContext` nor uses the stable `connectionID` as durable logical identity.

Therefore, if durable session A exists and a later lifecycle offer for session B (or another global recovery boundary) sets `coordinatorNeedsRecovery`, explicit retry creates another durable row for A. The dictionary retains only the replacement row. Shutdown closes only rows still present in that dictionary (`ViewerStoreCoordinator.swift:598-620`), leaving A's original row active until a later process performs orphan reconciliation. History now falsely shows two device sessions for one uninterrupted connection, the first with an interruption ending, and retry is not idempotent by stable device identity as required by the design.

The current retry tests cover unavailable startup/reopen, nondurable mid-runtime materialization, failed ingress prefixes, and prior-runtime generation replacement, but none calls `recoverSession` for an already durable connection or drives one missed lifecycle offer while another durable session remains active.

**Required resolution:** assign and retain one stable logical device identity before durable admission, make `sessionStarted`/`recoverSession` idempotently return or gap-account the existing `DeviceContext`, and recover only missing nondurable sessions. Preserve gap accounting for observations missed while global recovery was active without creating a second row. Add deterministic tests for direct duplicate start/recovery, one missed lifecycle offer with another durable live session, repeated retry, shutdown after retry, and next-open verification that exactly one device row exists and no false orphan/interruption was created.

### NW-LSS-IMPL-R4-CT-002 — Medium — Metadata and annotation capacity admission uses a stale reader-side preflight

`updateRecording` and `appendAnnotation` call `ensureLogicalCapacity` before entering the writer executor (`ViewerStoreMaintenance.swift:246-263,303-315`). That helper reads quota on the independent query connection and may run cleanup (`ViewerStoreMaintenance.swift:855-873`); only afterward does the operation enqueue its writer transaction, where `addQuota` rechecks capacity (`ViewerStoreMaintenance.swift:263-298,315-342,830-852`). Another Event, metadata mutation, or annotation can commit between the reader-side preflight and the writer transaction.

Two concurrent valid mutations can thus both observe enough space, the first consume it, and the second fail `.capacityExceeded` inside its transaction without the single planned cleanup/retry used by `ViewerEventStore.writeTransaction`. Eligible closed history can exist, yet the mutation fails, the authoritative store state need not become `capacityPaused`, and the Round 3 claim that the same writer-executor plan drives admission, filesystem reserve, and one cleanup retry is false for these paths. There is no concurrent-capacity regression for metadata or annotations; the new whole-transaction test covers Event insertion only.

**Required resolution:** move metadata and annotation plan/admission onto the writer executor and use one shared bounded retry protocol that recomputes the plan after cleanup. The capacity decision, disk reservation, revision check, quota update, and insert must use one authoritative writer ordering. Add deterministic concurrent tests at exact capacity for annotation-versus-Event, annotation-versus-annotation, and metadata-versus-Event with eligible and protected history, verifying the correct commit/retry/pause result and safe status.

### NW-LSS-IMPL-R4-CT-003 — Medium — Invalid structural observations can trigger destructive cleanup before validation

`appendStructural` asks `plannedStructuralReservation` for a positive plan before the body validates several payload bounds (`ViewerEventStore.swift:484-650`). The planner does not first enforce the body's policy size, drop count/reason, or gap count/reason/time/direction/range rules (`ViewerEventStore.swift:660-790` versus `ViewerEventStore.swift:585-650,820-878`). `writeTransaction` may run a threshold cleanup as soon as this positive plan crosses capacity, before `BEGIN` and before the body rejects the observation (`ViewerEventStore.swift:1308-1360`). An invalid new policy/drop/gap can therefore tombstone eligible user history and then fail `.invalidValue`; validation failure is not side-effect free.

These values are Viewer-internal rather than untrusted network models, but the capability explicitly requires hard bounds and safe failure injection, and the task plan claims exact boundary tests. Current tests verify valid structural idempotency/conflicts and some text bounds, but not that invalid structural observations perform zero cleanup/quota mutation at a capacity boundary.

**Required resolution:** make the plan function perform every pure validation that the body requires before returning any reservation or invoking cleanup, preferably through one shared validated representation so plan and mutation cannot drift. Add capacity-boundary tests for oversized policy JSON, zero/negative drop count, invalid drop reason, invalid gap count/time/direction/wire range, and overlength gap reason; assert no tombstone, quota change, or status misclassification occurs.

### NW-LSS-IMPL-R4-CT-004 — Medium — A 128-byte trailing-dot Event-type prefix is accepted although no valid Event type can match it

The revised Event-type prefix validator permits one trailing empty segment as long as the complete prefix is at most 128 bytes (`ViewerStoreQuery.swift:287-314`). A prefix consisting of a valid 127-byte segment plus `.` therefore passes. Every persisted Event type is itself limited to 128 bytes, and completing the empty final segment requires at least one ASCII letter, so no valid Event type can begin with that prefix. This is an impossible prefix that the Round 3 remediation says the closed validator rejects.

The current grammar regression covers overlength exact values, ordinary trailing-dot prefixes, partial segments, malformed separators, Unicode, and non-ASCII JSON indexes (`ViewerStoreTests.swift:472-513`), but not the maximum-length trailing-dot boundary.

**Required resolution:** require a trailing-dot prefix to leave at least one byte for a valid next segment (or define an equivalent shared `EventType` prefix validator). Add 126/127/128-byte exact, partial, and trailing-dot boundary tests proving every accepted prefix can match at least one valid Event type.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 4 — 1 High, 3 Medium, 0 Low.**

Round 3 materially improved complete Event admission, query grammar, export hardening, reflection safety, and evidence. Completion still requires idempotent same-coordinator device recovery, writer-authoritative metadata capacity admission, validation-before-cleanup for structural inputs, and the remaining impossible-prefix boundary.
