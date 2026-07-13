# Implementation Review Round 2 — Architecture/API

Date: 2026-07-13

## Verdict

**Not approved. Exact unresolved actionable finding count: 9 — 8 High, 1 Medium, 0 Low.**

This was a fresh review of the current production source, tests, documentation, Xcode project, active OpenSpec artifacts, Round 1 reports, and remediation state. Round 1 materially improved runtime-scoped recording ownership, immutable lifecycle bases, recording-local aliases, event/disposition integration, frozen-query identity, export shape, quota attribution, and safe status delivery. The repository boundary also remains appropriate: SQLite is Viewer-only and the small Core change only retains an already-validated transport byte count through the internal SPI value.

Configured signing, entitlement, and stable-signer validation are explicitly deferred by the user to the final `release-hardening` change and are not findings in this review. The unsigned/local artifact gates passed: strict OpenSpec validation reported `Change 'viewer-local-store-search' is valid`, and `git diff --check` exited successfully with no output.

## Findings

### 1. High — The two-stage journal pipeline exceeds the one bounded-ingress contract

The protocol-facing preparation queue independently permits 8,192 normal values and 64 MiB, plus 64 structural values (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:761-815`). The downstream ingress separately permits the configured 4,096/32-MiB default or 8,192/64-MiB hard Event budget and another 36 structural values (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:1001-1079`). Values can occupy both stages concurrently, so the runtime can retain more than the required 8,192 Events/64 MiB hard maximum and more than the single 36-value structural allowance. Documentation nevertheless describes one 4,096/32-MiB ingress and one 36-record structural lane (`Documentation/Viewer-Local-Store.md:29`).

Required resolution: make preparation and writer admission share one count/byte/structural ownership budget, or remove one retained stage. Prove that the complete protocol-to-writer pipeline, not each queue independently, owns at most the specified default/hard Event limits, one 36-value structural lane, one drain, and one dirty successor.

### 2. High — Uplink terminal ownership still assumes peer Event UUID uniqueness

The session tracks pending journal identity in `[EventID: UInt64]` (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:191`). Admission stores and removes entries by `envelope.id`, including displaced/expired victims (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:621-674`), and terminal cleanup again resolves removed queue IDs through that dictionary (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:967-975`). The approved contract explicitly permits a peer to reuse an Event UUID at another valid wire sequence. A second buffered Event with the same UUID overwrites the first sequence; a later expiry, displacement, consumer acceptance, or session clear can therefore attach the terminal transition to the wrong sequence or leave one durable Event permanently nonfinal.

Required resolution: carry a store-independent journal token containing direction and wire sequence in every queued/in-flight entry and return that token from queue removal. Event UUID must remain ordinary content and must never index terminal ownership. Add duplicate-UUID coverage across buffering, expiry, displacement, consumer handoff, and session end.

### 3. High — A transition whose initial Event was not stored poisons the writer instead of becoming a gap

Initial Event admission and later terminal admission are independent. A rejected Event admission records a gap (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:257-280`), but a later terminal observation can still enter the structural lane (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:284-309`). The disposition writer requires the Event row and throws `invalidValue` when it is absent (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:446-455`). The ingress treats that expected missing-parent case as a general transaction failure, enters `writeFailed`, and stops every accepted recording (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:1152-1164`). This contradicts the required behavior that a transition without its initial row is ignored with gap accounting and that persistence cannot disrupt unrelated journaling.

Required resolution: make sequence-keyed disposition admission return a closed `missingInitialEvent` outcome, coalesce the corresponding incomplete-journal gap, remove only that handled structural value, and keep the writer available. Preserve `writeFailed` for genuine transaction/store-integrity failures.

### 4. High — A device that starts and ends during an existing writer outage leaves no durable gap

When device materialization fails, the coordinator retains the live context in `nondurableConnections` (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:202-209`). If that device ends before retry, `sessionEnded` removes the nondurable entry and returns when no durable device exists, without recording a recording-level unavailable interval (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:312-329`). Retry materializes only entries still present (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:435-446`, `:607-615`). The outer runtime's missed-observation counter only advances when the whole coordinator is absent, not when an existing coordinator is write-failed (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:989-1087`). The required “started and ended entirely during outage” gap is therefore lost in the common mid-runtime writer-failure case.

Required resolution: maintain one saturating recording-scoped unavailable interval/count whenever durable parent admission or ingress is unavailable, including nondurable sessions that end before retry. Retry must materialize only still-live devices while committing that bounded interval; shutdown/reopen must retain an equivalent recoverable aggregate.

### 5. High — Gap coalescing mutates frozen history and is not idempotent

`GapVersions` is specified as append-only and query/export snapshots freeze its AUTOINCREMENT upper bound. The implementation instead finds an existing `(recording, device, sequence)` row and updates `count` in place (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:537-555`). Replaying the identical structural observation adds the count again; the current test explicitly expects two identical count-2 offers to become 4 (`Viewer/NearWireViewerTests/ViewerStoreTests.swift:328-375`). Export later reads the mutable count from any row below the captured bound (`Viewer/NearWireViewer/Store/ViewerStoreExport.swift:386-417`), so an export/query snapshot can change after capture without a new row ID.

Required resolution: represent coalescing through append-only aggregate versions (or immutable range rows plus a separately versioned accumulator), resolve the latest version at or below the frozen bound, and make an identical sequence retry idempotent. Conflicting same-sequence content must fail only the store; a newly extended aggregate must receive a new version identity.

### 6. High — Physical reclaim exceeds one-turn bounds and never performs free-page reclamation

One reclaim turn selects up to 1,024 Event rows based only on Event quota (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:434-459`), then deletes all matching disposition rows and the Events, whose trigger also mutates FTS (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:466-477`). A normal Event may own both initial and terminal disposition rows, so one turn can delete well above 1,024 child/index rows and its 4-MiB selection omits dependent disposition/FTS work. After phased deletion, the only storage optimization is a passive WAL checkpoint (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:614-635`); there is no incremental vacuum/free-page step even though the design and documentation promise one (`openspec/changes/viewer-local-store-search/design.md:112-123`, `Documentation/Viewer-Local-Store.md:37`). Main-database allocated footprint therefore need not fall after physical reclaim.

Required resolution: account all Event-owned disposition and FTS mutations in the row/byte turn budget (with the specified one-Event oversize exception), and add a bounded incremental free-page operation as a distinct maintenance turn. Persist/resume its campaign state and test large disposition/FTS fan-out and allocated-footprint progress.

### 7. High — Required query semantics and continuation identity are still incomplete

The receive-time predicate compiles against App `createdWallMs` instead of Viewer `viewerWallMs` (`Viewer/NearWireViewer/Store/ViewerStoreQuery.swift:140-149`). JSON string containment casts any extracted scalar to text and does not require `json_type(...)='text'`, so numeric and Boolean values can match a string-only predicate (`Viewer/NearWireViewer/Store/ViewerStoreQuery.swift:174-178`). The cursor binds a lease ID but not the required lease expiry (`Viewer/NearWireViewer/Store/ViewerStoreQuery.swift:279-287`), while recording/device-version and disposition upper bounds are captured but are unused by page/detail SQL and absent from the summary/detail API (`Viewer/NearWireViewer/Store/ViewerStoreQuery.swift:270-312`, `:373-478`). Thus the API does not actually expose a frozen resolved disposition/lifecycle view even though those bounds are presented as part of traversal identity.

Required resolution: compile receive-time against Viewer admission time, type-gate JSON containment, and make one opaque continuation own fingerprint, recording scope, all upper bounds, lease token plus expiry, direction, and keyset. Resolve every summary/detail metadata value, including local disposition when exposed, only at the frozen bounds; remove bounds that are genuinely outside the API rather than claiming they participate.

### 8. High — Export replacement can report failure after permanently deleting the prior destination

For an existing destination, export swaps the new temporary and old destination, synchronizes the directory, unlinks the old file, and synchronizes again (`Viewer/NearWireViewer/Store/ViewerStoreExport.swift:604-640`). If the final directory `fsync` fails, the method throws after the prior file has already been unlinked and cannot restore it. The caller leaves `committed == false` (`Viewer/NearWireViewer/Store/ViewerStoreExport.swift:158-184`), yet the destination contains the new export and the old destination is gone. This violates the atomic API contract that failure before the reported commit preserves the prior destination.

Required resolution: define one irreversible commit boundary. Do not return a pre-commit failure after deleting the rollback copy; either retain and restore the prior inode through all fallible pre-commit phases or treat the first durable swap as committed and report any later cleanup issue separately. Add injected failures for swap, first sync, old-file removal, and final sync with exact destination-state assertions.

### 9. Medium — Explicit cleanup bypasses the single maintenance owner and blocks `MainActor`

The application invokes cleanup synchronously from its `@MainActor` model (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:6-7`, `:160-163`). The live dependency calls `ViewerStoreMaintenance.run` directly (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:935-940`) rather than submitting through `ViewerStoreMaintenanceOwner`, while automatic startup/threshold/periodic work uses that separate owner (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:734-876`). An explicit cleanup can therefore occupy the UI thread for eight SQLite turns and coexist as a second maintenance task, contradicting both responsive presentation ownership and the “one maintenance task plus one dirty successor” limit.

Required resolution: make cleanup an asynchronous request handled by the same maintenance owner/state machine as every other trigger, return a bounded safe outcome to the application model, and update presentation only through the latest-only status stream. Prove concurrent explicit/threshold/settings/periodic triggers collapse to one active campaign and one successor.

## Approval Gate

Resolve all nine findings, add requirement-matched tests/evidence, rerun the affected unsigned/local gates, and obtain a fresh architecture/API review with **0 unresolved findings**. Configured signing and stable-signer validation remain outside this change and must be completed only in the user-directed final `release-hardening` change.
