# Implementation Review Round 1 — Architecture/API

Date: 2026-07-13

## Verdict

**Not approved. Exact unresolved actionable finding count: 8 — 7 High, 1 Medium, 0 Low.**

This review covers the stable current uncommitted production, tests, documentation, Xcode project, and active OpenSpec artifacts. The repository boundary is correct: the system SQLite implementation remains under Viewer, no persistence dependency enters Core or SDK, and no nested package manifest or third-party runtime dependency was added. The implementation also keeps Event Explorer, timeline/detail UI, control composition, and performance charts out of this change.

The remaining issues are implementation-to-spec architecture mismatches, not documentation polish or missing test volume.

## Findings

### 1. High — Recording ownership follows the device count instead of the Viewer runtime

The approved design requires one stable recording context to begin before the runtime accepts device handoffs, survive periods with zero devices and pairing/listener replacement, and close only during full runtime shutdown. The implementation instead creates the recording lazily when the first device is accepted (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:86-100`, `:206-214`) and closes/clears it as soon as the last current device ends (`:131-157`). A disconnect followed by a reconnect in the same open Viewer runtime therefore produces two recording sessions.

The application shutdown path drops its session-manager reference after the admission receipt begins but has no store-runtime start/end or flush dependency (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:261-296`). `ViewerStoreCoordinator.shutdown()` is not called anywhere, and when called directly it discards ingress immediately (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:190-204`). The live dependency creates one optional coordinator outside the listener runtime and exposes only a state-flip retry (`Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:22-27`, `:46-78`).

Required resolution:

- make the application runtime explicitly begin one logical recording before listener handoff and end it only after exact session cleanup and a finite store flush;
- preserve that context across zero-device intervals, pairing refresh, and listener collision replacement;
- bind store cleanup ownership to the existing shutdown receipt rather than discarding pending values; and
- implement a real reopen/retry path for unavailable construction and failed writers instead of changing only the status enum.

### 2. High — Uplink journaling observes consumer handoff, not committed wire Events or their terminal state machine

The live dependency routes `journal.received` through the existing uplink consumer closure (`Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:46-54`). The session commits a validated frame and queue state at `ViewerMultiDeviceSession.swift:550-594`, but it emits no journal Event there. The supplied closure runs only after a later dequeue and successful handoff (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:597-636`). `ViewerPreparedEventObservation` consequently labels every such uplink row immediately `consumerAccepted` (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:37-50`).

Valid committed Events that expire, are immediately overflow-dropped, are later displaced, or are cleared by terminal cleanup never reach the store. There is no journal API for sequence-keyed later disposition transitions, policy samples, or changed drop samples (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:5-14`), and the `.disposition` storage case is not called by production code. This defeats the central append-only commit/transition model and makes persisted history a consumer-delivery subset rather than committed protocol history.

Required resolution:

- publish one immutable, constant-bounded Event-commit observation immediately after the frame-wide sequence/queue transaction commits;
- carry the `(recording, device, direction, wireSequence)` journal key with each queue entry;
- emit exactly one idempotent terminal transition for consumer acceptance, later expiry/displacement, or session end, including earlier overflow victims; and
- publish changed policy/drop samples without giving storage sequence, queue, token, mailbox, or terminal authority.

### 3. High — Store ingress loses failed and shutdown work instead of preserving the bounded retry prefix and coalesced gap

The ingress removes a structural value or Event batch from its arrays before writing (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:659-693`). Although current Event batches now use one transaction, any write failure simply clears scheduling state and returns (`:695-703`); the rolled-back prefix is neither restored nor converted into a durable/coalesced gap. Later admissions can continue, so the exact missing interval is not represented.

Loss accounting allocates a new structural gap observation with a new sequence for each rejected Event (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:238-257`). It is not one saturating per-recording coalesced aggregate and can exhaust the 36-value structural lane; rejection of that gap is ignored. `stop()` removes every accepted Event and structural observation immediately (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:641-647`), and `retry()` merely sets state to available (`:325-329`).

Required resolution:

- retain the failed finite transaction prefix inside ingress for one explicit retry boundary;
- stop automatic drain polling after failure while coalescing subsequent losses into one bounded aggregate per recording/direction/reason domain;
- preserve structural close ownership separately and define the winner when its lane is saturated; and
- implement a finite asynchronous flush that keeps queue/connection ownership alive through the cleanup receipt, rather than clearing admitted work.

### 4. High — The schema contradicts immutable/versioned snapshot ownership and makes installation aliases global

The approved schema makes recording/device bases immutable and represents end, partial-history, terminal, nickname, name, note, and pin changes through append-only versions. The actual base tables contain mutable end and partial-history fields (`Viewer/NearWireViewer/Store/ViewerStoreSchema.swift:71-114`), and close/reconciliation mutates them in place (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:219-239`; `Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:259-302`). No terminal recording/device version is appended. Frozen recording/device version IDs therefore do not freeze the lifecycle metadata that queries and exports display.

`InstallationAliases` has neither a recording owner nor a recording-local uniqueness key; installation ID and ordinal are globally unique (`Viewer/NearWireViewer/Store/ViewerStoreSchema.swift:94-99`). Alias lookup and allocation are likewise global (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:331-358`). This violates the recording-local `device-N` contract, creates stable cross-recording pseudonyms, and leaves raw installation identifiers behind because physical recording deletion never reclaims alias rows (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:380-419`).

Required resolution:

- move every mutable lifecycle field into append-only version rows and make close/reconciliation append child versions before the parent version;
- make installation aliases recording-owned with recording-local ordinal/identity constraints and cascading/bounded reclaim ownership; and
- ensure query/export upper version and base-row bounds actually govern every emitted metadata value.

### 5. High — Tombstoning does not implement quota selection or bounded whole-recording reclamation

Per-recording quota attribution is never updated beyond the base recording's fixed structural reservation. Maintenance nevertheless selects `r.quotaBytes` as the recording's size (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:264-286`). The candidate query uses one global “quota above 85%” Boolean for every row, so it selects up to 32 recordings rather than accumulating oldest eligible sizes until the low-water target. The tombstone transaction then adds tombstone quota (`:289-307`) instead of atomically subtracting the selected recordings' exact visible quota as required.

Event deletion is bounded, but after Events are gone `deleteEmptyRecording` deletes every policy, drop, device-version, gap, annotation, recording-version, tombstone, and device row in one unbounded transaction (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:380-419`). The live coordinator also constructs maintenance without its active-recording provider (`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:61-67`), so backend manual deletion does not have the required active-session authority. No threshold or 15-minute maintenance owner exists, and changing settings only saves `UserDefaults` without running maintenance (`Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:57-61`).

Required resolution:

- maintain exact schema-owned per-recording and total quota counters in every insertion/version/tombstone transaction;
- select retention first and then oldest eligible recordings cumulatively toward 85%, subtracting the exact selected visible quota atomically;
- reclaim every child table through finite resumable row/byte turns, not only Events;
- inject one authoritative active-recording/lease registry into manual and automatic selection; and
- add the specified startup/settings/session-close/threshold/single-periodic-wake trigger ownership and exact 85%/100% pause behavior.

### 6. High — Query APIs do not bind traversal identity or implement the specified filter semantics

The query model exposes one global `.all`/`.any` switch and combines every predicate with that separator (`Viewer/NearWireViewer/Store/ViewerStoreQuery.swift:25-36`, `:130-134`). The required contract is AND across dimensions and OR only among values inside the same dimension. App/Bundle correlation, terminal/gap/drop presence, JSON existence, and JSON-path string containment are absent from the predicate model (`:13-23`). `contentContains` scans the complete JSON blob and is not the required path-specific containment operation.

The cursor contains only `(viewerMonotonicNanoseconds, rowID)` (`:209-212`). Page callers pass query, compiled SQL, snapshot, lease, cursor, and direction independently (`:264-308`); the compiler fingerprint is never checked, so a cursor/snapshot can be reused with different compiled semantics. Captured recording/device/disposition/gap/drop upper bounds are not applied by the Event SQL, and point detail accepts neither recording scope nor lease/fingerprint (`:311-328`). Work-budget interruption also has no API distinction from ordinary cancellation/refine-query behavior.

Required resolution:

- expose a normalized internal query whose dimension groups encode the mandated AND/OR semantics and all V1 filters;
- return an opaque continuation containing and validating query fingerprint, recording scope, every relevant upper bound, lease identity/expiry, direction, and keyset key;
- apply frozen version/sample membership when resolving summaries and detail; and
- require exact recording scope and traversal context for detail, rejecting stale/mismatched cursors without fallback.

### 7. High — Export is neither the required source API nor a frozen schema-version-1 result

The exporter accepts an arbitrary array of up to 32 recording IDs (`Viewer/NearWireViewer/Store/ViewerStoreExport.swift:50-63`, `:212-218`), while the contract allows one complete recording or one validated query. The global export lease is not bound to the source recording (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:86-114`).

The JSON root contains only `disclosure`, `devices`, and `events` (`Viewer/NearWireViewer/Store/ViewerStoreExport.swift:84-97`). It omits the required schema version, session object, gaps, and annotations. Event output omits causality, App monotonic/source metadata, TTL/schema, and local disposition; it orders by Event row ID rather than `(viewerMonotonicNs, rowID)` (`:139-189`). The captured recording/device/disposition/gap/drop/annotation upper bounds are unused by the emitted queries (`:191-205`), and device pages read the mutable base end/partial fields directly (`:99-137`). A long export can therefore combine lifecycle metadata from after capture with Events from before capture.

Required resolution:

- define one source enum for complete recording versus validated frozen query and acquire a lease for that exact recording;
- stream the full schema-version-1 `session`, `devices`, `events`, `gaps`, and `annotations` document in Viewer receive order;
- share the normalized query compiler with on-screen search and honor every frozen base/version/sample bound; and
- include all required safe Event metadata and resolved local disposition while preserving the forbidden-field and bounded-memory contract.

### 8. Medium — Storage status/settings bypass the latest-only presentation boundary and omit required operational state

`ViewerStoreStatus` contains only state, total logical bytes, allocated footprint, oldest date, and pinned bytes (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:90-103`). It omits recent ingest rate, estimated retained duration, last cleanup result/category, and a commit upper bound/change notification. Pinned usage is calculated from only each recording base's fixed quota rather than the recording's attributed total (`:283-313`).

The `MainActor` application model synchronously loads SQLite status during initialization and every manual refresh (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:48-54`, `:145-155`) instead of consuming a latest-only presentation model. No commit/maintenance notification refreshes status, configuration save does not run the required settings-change maintenance, and “Retry Storage” can report success after only changing an enum. The UI labels configured retention rather than providing the required estimated retained duration (`Viewer/NearWireViewer/UI/ViewerRootView.swift:155-217`).

Required resolution: introduce one bounded latest-only storage presentation stream owned by the application model, populate all specified safe status fields from authoritative counters/maintenance results, keep SQLite/file I/O off `MainActor`, and make save/cleanup/retry actions report their real asynchronous outcome.

## Validation

Current stable-tree commands:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
git diff --check
```

Results: strict OpenSpec validation passed (`Change 'viewer-local-store-search' is valid`), and `git diff --check` passed with no output.

An additional arm64 Viewer test run built the changed source and all 11 `ViewerStoreTests` passed. The overall test action exited 65 because two existing entitlement assertions ran with `CODE_SIGNING_ALLOWED=NO`; this does not resolve the architecture findings above. A default dual-architecture invocation also hit an explicit-module resolution failure, so packaging evidence still needs the repository's intended signed/stable-signer commands.

## Approval Gate

Resolve all eight findings, add requirement-matched evidence, rerun validation and affected suites, and obtain a fresh architecture/API implementation review with **0 unresolved findings** before this OpenSpec change can complete.
