## Context

`viewer-multidevice-flow-control` established exact connection/session ownership, receiver-local TTL validation, atomic sequence commit, bounded in-memory queues, and a globally bounded nonblocking uplink consumer boundary. Its live implementation intentionally keeps Event content, session epochs, effective policy, and queue contents out of `UserDefaults`, logs, UI state, and persistence.

This change introduces the first deliberate durable Event-content boundary. It must preserve two independent truths:

1. The device session remains a real-time protocol system. Storage may observe committed outcomes but must never become part of sequence, mailbox, timeout, or terminal ownership.
2. The database is a local analysis journal, not a delivery acknowledgement. A stored downlink Event means Viewer admitted its bytes to the secure mailbox, not that the App received or processed it.

The root package already supplies validated Event models and wire-received values to Viewer. Persistence, SQL, search, export, and storage UI are macOS product concerns and therefore remain under `Viewer`.

## Goals / Non-Goals

**Goals:**

- Automatically journal the current Viewer runtime and every accepted device connection without requiring a recording button.
- Preserve enough validated Event and session data for later single-device and merged timelines, detail inspection, causality, performance projections, and audit of Viewer control Events.
- Bound memory, transaction work, query pages, disk quota, retention, cleanup work, and notification delivery.
- Make live and historical queries use the same persisted source of truth.
- Protect active and pinned recording sessions from automatic deletion.
- Stream large exports with deterministic aliases and no full-result materialization.
- Keep network sessions operating when storage is slow, full, corrupt, unavailable, or explicitly paused after failure.

**Non-Goals:**

- The three-column event explorer, JSON tree/raw renderer, virtual timeline rows, pause-rendering control, control-event composer, or performance charts.
- Import, CSV, `.nearwire` archives, replay, delivery acknowledgement, templates, favorites, or independent send history.
- At-rest encryption, SQLCipher, cloud synchronization, a service process, a database shared between users, or remote access.
- Persisting raw frames, pairing codes, certificates, private keys, endpoints, queue keys, or exact session epochs.
- A public SDK persistence/search API or any Core database abstraction.

## Decisions

### 1. Viewer uses system SQLite through three bounded connection owners

The Viewer Xcode project links `libsqlite3.tbd` and imports the system `SQLite3` module. No SQLite wrapper is added to the root `Package.swift`, CocoaPods specification, Core, or SDK. A small Viewer-internal wrapper owns exactly three connections after migration: one writer, one interactive-query reader, and one export reader. Each connection and every statement/raw pointer is confined to its own serial executor. At most one interactive query operation and one export operation execute at a time; the writer remains independently serviceable. No pointer, raw SQLite error, SQL text, or database path crosses an executor or reaches a safe surface.

The live database resides in the app's Application Support container under a versioned NearWire directory. The directory is mode `0700`; the database, WAL, SHM, rollback-journal/migration artifacts, and export temporary files are regular nonsymlink files with mode `0600`. Open uses no-follow support where available and validates the parent and every known sidecar before and after WAL activation and close. SQLite temporary storage remains memory-only and every query has a VM-step/time budget so an unbounded temporary sort cannot form. Startup enables foreign keys, WAL journaling, bounded busy timeout, `secure_delete=ON`, trusted-schema restrictions, and defensive connection settings where supported. Secure delete is defense in depth only: retention is logical application deletion, not guaranteed erasure from WAL history, filesystem snapshots, or backups.

Schema creation and every migration run on the writer in an immediate transaction before read connections open. `PRAGMA user_version` identifies schema version 1; a newer unknown version fails safely without destructive downgrade or recreation. V1 requires SQLite JSON1 and FTS5 and probes both with fixed statements before accepting writes.

The query and export executors use short read transactions per bounded page; neither holds a read transaction while awaiting UI or file I/O. Each connection installs a progress handler with a generation-bound atomic cancellation flag and operation-specific VM-step/time allowance. A cancellation controller may call thread-safe `sqlite3_interrupt` only when the same generation is still the active operation on that exact connection. Completion clears active generation before a later operation starts, so a late cancel cannot interrupt a following write/query/export.

Missing features, open failure, migration failure, corruption, or schema mismatch yields one closed safe category. The network runtime may still start, but journaling/search/export remain unavailable until an explicit successful retry. Viewer never deletes or recreates an unreadable database automatically.

### 2. Logical recording identity exists even when durable admission does not

One stable in-memory `ViewerRecordingContext` begins before the application runtime accepts device handoffs. It owns a random recording ID, start wall/monotonic time, and saturating next device/installation-alias ordinals independently of SQLite availability. Pairing-code refresh and listener collision replacement keep that context. Closing the last window, terminating the application, resetting identity, or another full runtime shutdown ends it after device cleanup and the final bounded store attempt. A later window creates a fresh context while prior durable history remains queryable.

Durable guarantees are conditional. A recording row exists only after the writer commits the context's parent admission. A device row exists only after that parent and the exact device start commit in causal order. Event/sample rows are eligible only after their device row commits. When storage is unavailable at startup, the listener remains live with a logical non-durable context; no artifact claims that a row exists.

An explicit successful retry during the same runtime first materializes the original recording ID and start time, records one coalesced `storageUnavailable` gap spanning the missing interval, then materializes only device sessions that are still live, using their original stable IDs/ordinals and marking their history partial. Queue admission is not recovery completion: the runtime moves the current missed-observation count into a generation-bound claim and clears that claim only after recording/device materialization and bounded gap ownership succeed. Admission or materialization failure merges the claim back with any observations received during the attempt using saturating arithmetic. Events become eligible only after those commits. A device that both connected and ended while storage was unavailable is represented by the bounded gap rather than reconstructed as a false complete row. If storage remains unavailable through shutdown, no durable recording is invented.

If a previously durable writer fails, structural lifecycle uses a separate fixed control allowance derived from one recording plus the 16 live-device bound; Event observations cannot consume it. A durable open device/recording whose close cannot commit remains recoverable rather than causing unbounded memory retention. On every successful reopen, one reconciliation transaction handles exactly one prior recording group: it validates at most 16 open device children, appends all device interruption versions first, then appends the parent recording interruption version in the same commit. More than 16 open children is schema corruption and fails closed. Reconciliation owns at most eight immediately chained group turns. No cleanup may select a still-open parent between turns, and a new durable recording is admitted only after zero prior open groups remain; otherwise networking may continue non-durably until a later explicit retry. Duplicate start/close operations are idempotent by stable ID and monotonic revision. This covers repeated crash/failed-flush histories without unbounded startup work, parent-before-child closure, or permanently protected active rows.

Each accepted connection receives one stable logical `ViewerRecordedDeviceSession` ID and ordinal, but creates a durable row only under the rules above. A durable row stores bounded App metadata, the peer-declared installation identifier for local correlation, Bundle ID, optional nickname snapshot, start/end times, partial-history marker, and terminal category. These remain unauthenticated correlation hints. Raw pairing codes, Bonjour names, endpoints, certificate data, and TLS selectors never enter the schema.

The schema contains:

- `recording_sessions`: immutable recording identity/start, accounting, ordinals, and cleanup state;
- `recording_versions`: append-only end/name/note/pin revisions;
- `device_sessions`: immutable connection identity/start and bounded App correlation metadata;
- `device_session_versions`: append-only partial-history/terminal/nickname revisions;
- `events`: immutable validated logical Event content and metadata plus Viewer receive/admission ordering and admission disposition;
- `event_disposition_transitions`: append-only idempotent terminal outcomes for queued uplink Events;
- `flow_policy_samples`: requested/effective directional values sampled only on change;
- `drop_samples`: monotonic cumulative queue/drop observations sampled only on change;
- `gaps`: coalesced ranges that explain unavailable persistence or known local loss;
- `annotation_versions`: append-only bounded user-note versions reserved for the next explorer;
- `installation_aliases`: recording-local deterministic ordinals used directly by export;
- `store_metadata`: schema-owned accounting, sequence, and cleanup campaign state;
- `event_fts`: an FTS5 external-content index maintained transactionally with `events`.

Foreign keys use recording ownership. Visible queries exclude logically deleted/tombstoned recordings. All writes use prepared statements and checked integer/byte conversions. Event content is stored as deterministic ordinary JSON, never the internal tagged Codable representation and never raw wire bytes. Event row IDs and every append-only recording/device/transition/gap/sample/annotation version ID use `INTEGER PRIMARY KEY AUTOINCREMENT`; IDs are never reused after deletion.

### 3. Protocol commit publishes an immutable Event followed by append-only disposition transitions

The session manager receives a `ViewerJournalSink` when constructed. The sink observes immutable Viewer-internal values and has no method that can affect the connection core.

For App-to-Viewer traffic, the session emits an immutable Event-commit observation after an entire frame has passed route/schema/sequence/deadline validation and its sequence range commits. Its admission disposition is terminal when already expired or immediately overflow-dropped; otherwise it is `buffered`. The durable Event has a unique journal key of `(recordingID, deviceSessionID, direction, wireSequence)`; peer Event UUID remains ordinary content because a peer may reuse it at another valid sequence. A buffered row later receives exactly one append-only terminal transition addressed by that journal key and transition kind: `consumerAccepted`, `expired`, `overflowDisplaced`, or `sessionEnded`. Duplicate identical transitions are idempotent; a conflicting second terminal transition is a safe store-integrity failure and cannot alter the network session. An overflow victim from an earlier frame emits its own sequence-keyed transition before the newer frame's changed drop sample. A structurally invalid frame produces no Event row because sequence never commits.

`consumerAccepted` means the existing bounded uplink consumer handoff accepted ownership; it does not claim UI rendering, persistence by another system, or user processing. If a transition cannot be journaled, a coalesced gap records missing journal state and the durable Event remains explicitly nonfinal rather than being mislabeled. A transition whose initial Event row was never committed is ignored with gap accounting.

For Viewer-to-App traffic, the session creates observations only after one Event or Event-batch frame is synchronously accepted by the secure mailbox and its sequence/queue/token transaction commits. Queue admission, keep-latest replacement, local expiry, route drop, encoding failure, and mailbox rejection do not create a sent Event row. The stored disposition is `transportAdmitted`; it never claims peer receipt or processing.

Policy and drop samples are emitted only when their persisted value changes and are append-only. Device-session terminal observation is idempotent. Every observation carries the exact recording/device key and a Viewer monotonic sample. App Event wall time is preserved separately; Viewer wall receive/admission time is captured for display and cross-runtime history only. Within one recording session, merged ordering uses `(viewerMonotonicNanoseconds, eventRowID)`; the row ID is a deterministic tie breaker, not a transport sequence.

The wire decoder already validates and computes each record's deterministic encoded byte count. Journal observations retain the validated value through Swift copy-on-write storage and carry that precomputed count plus a checked fixed metadata reservation. Lock admission reads only these scalars and performs no JSON encoding, string walk, SQLite binding, or deep copy on the protocol executor. Canonical JSON and every other linear content operation occur after admission on the writer executor. A maximum legal batch performs one bounded constant-time offer per already-validated record; rejected offers do no content walk.

Journal offer is nonthrowing and constant-bounded per record from the protocol executor's perspective. Storage success, failure, or lag never changes wire sequence, queue ownership, rate tokens, mailbox state, or terminal state.

### 4. Store ingress separates structural control from lossy Event observations

`ViewerStoreIngress` is lock-protected and owns at most 4,096 Event/sample/transition observations or 32 MiB by default, with hard maxima of 8,192 observations and 64 MiB. A separate fixed structural-control lane owns at most 36 coalesced recording/device start/close/reconcile values derived from one recording and the 16-live-session bound. Event traffic cannot consume structural capacity. It schedules at most one drain plus one dirty successor on the writer executor.

The normal transaction quantum is 256 observations or 4 MiB. One single Event observation may instead use one-record oversize mode up to a hard 20 MiB reservation so every Event admitted by the current 16-MiB Viewer queue/negotiated frame bound has a coherent journal path. Session construction proves the exact negotiated maximum observation fits that hard bound and the default ingress. An impossible larger observation becomes one gap before ingress and cannot block the queue head. SQLite/FTS physical amplification is not claimed to equal the reservation or the 4-MiB quantum.

When Event ingress cannot accept an observation, it increments saturating per-recording counters and coalesces one pending gap containing reason, first/last Viewer time, affected directions, and count. It does not allocate one gap per dropped Event. When writing later resumes, the next successful transaction records that gap before later Events. If the recording ends while storage remains unavailable, current safe status retains the bounded aggregate but no false durable gap is claimed.

SQLite busy handling is bounded. A busy or I/O failure rolls back the whole transaction, preserves the finite uncommitted prefix for one explicit retry boundary, changes the store to `writeFailed`, and stops automatic retry polling. New Event observations coalesce into the pending gap rather than growing memory. Structural close state remains in its fixed lane or is repaired by next-open reconciliation. A user retry, successful database reopen, storage-setting change, unpin, or manual deletion may trigger one new attempt. Corruption and unknown-schema failures remain fail-closed until external repair or user-chosen replacement in a later recovery UI.

### 5. Capacity uses deterministic quota accounting and bounded logical deletion

`ViewerStoragePreferences` is a bounded versioned `UserDefaults` value. Defaults are exactly 3 GiB and seven days. Capacity accepts 64 MiB through 1 TiB. `historyRetention` accepts one through 3,650 days. Invalid, oversized, unknown-version, nonintegral, or corrupt data is replaced with defaults. UI and documentation never call history retention Event TTL.

The configured 3-GiB value is a deterministic NearWire history quota, not a promise that every SQLite sidecar byte or filesystem snapshot equals it. Each immutable Event reserves `2 * deterministicCanonicalEventBytes + 1 KiB`; lifecycle/sample/transition/annotation rows use fixed checked reservations. The multiplier accounts conservatively for the Event row plus FTS content. Schema-owned recording counters and one total are updated in the same transaction as each insert or logical deletion and are the only selection metric. Peer-declared byte values are never trusted. Arithmetic overflow rejects the journal operation into a gap.

Status separately reports quota-accounted live bytes and allocated database/WAL/SHM footprint. Before every write transaction, a volume-capacity safety check requires a bounded reserve based on the planned transaction with a 64-MiB floor; insufficient filesystem capacity pauses writes even when logical quota remains. The product documents that physical SQLite/filesystem use may differ from quota accounting.

Maintenance runs at startup, after a settings change, after a completed recording session, and after committed writes cross a bounded accounting threshold. One replaceable 15-minute wake while a runtime is active provides periodic cleanup; no task is created per session or Event. Settings-triggered recovery authority is bound to the exact monotonic settings revision that justified it. A newer edit replaces the pending decision even when it is not recovery-eligible, and an older running campaign rechecks the revision before publication so a reverted limit cannot reopen writes.

Cleanup is a bounded campaign with at most eight immediately chained turns per trigger. One turn performs exactly one bounded mutation: mark at most 32 recording sessions, reclaim at most 1,024 child rows/4 MiB, or perform one checkpoint/free-page step, then yields. A logical-selection turn uses quota-accounted bytes in this order:

1. mark closed unpinned recording sessions whose end time is at or before the history-retention cutoff;
2. if visible quota usage remains above capacity, mark oldest closed unpinned sessions by end time and ID until usage is at or below 85% of capacity or the turn/campaign bound is reached;
3. atomically set each selected recording to `deleting`, remove it from every visible query/export candidate, and subtract its exact quota counter;
4. commit none of the selected marks if validation or mutation fails.

Active, pinned, or read-leased recordings are never selected. If eligible sessions are exhausted with quota usage above 85% but at or below 100%, Viewer remains writable and reports that low-water could not be reached. If visible usage remains above 100%, writing pauses until cleanup or configuration change succeeds. The 85% target never causes protected data deletion.

Physical reclamation follows logical deletion through later bounded campaign turns. A normal reclaim removes at most 1,024 child rows or 4 MiB of reserved data and matching FTS rows. If the FIFO head is one oversize Event, one-record reclaim MAY atomically remove that Event plus its FTS row up to a 41-MiB hard quota reservation, matching the maximum `2 * 20 MiB + 1 KiB` store formula rounded upward; a larger/impossible value fails safely instead of blocking later tombstones. One huge recording therefore cannot create an unbounded cascade transaction or task chain. Queries can never observe a partial recording because the parent tombstone wins first. A reclaim failure rolls back that physical batch and leaves the whole recording logically deleted/tombstoned for a later explicit, threshold, session-close, or 15-minute campaign; it does not immediately retry or resurrect a partially visible session. At most one maintenance task plus one dirty successor exists, and every campaign stops after eight turns.

Checkpointing and incremental free-page reclamation run only between bounded transactions. Maintenance identifies the next action before disk admission and checks only that action's exact bounded plan: selection metadata, normal or oversize reclaim, or the floor-only checkpoint/free-page step. Read-only/no-work inspection requires no speculative 41-MiB reserve. Their failure changes safe status and may pause writes under the filesystem safety guard, but cannot cause additional logical sessions to be selected or pretend a committed tombstone rolled back. Retention documentation describes logical deletion, notes that SQLite page reclamation need not immediately reduce APFS allocated bytes, and explicitly disclaims guaranteed secure erasure from WAL, snapshots, or backups.

Before accepting each write batch, the coordinator computes its checked net quota plan before the first mutation, including conditional aliases, base/version rows, initial dispositions, and gap/sample text reservations. Idempotent no-ops plan zero bytes. If the reservation would cross capacity, it runs one bounded cleanup campaign. The physical guard independently requires the volume to retain its 64 MiB floor after the bounded planned work. If protected/leased data or campaign bounds still prevent admission, it enters `capacityPaused`, accepts no further Event writes, keeps network sessions live, and coalesces a gap. Increasing capacity, unpinning, lease expiry, ending an active recording, or confirmed manual deletion may run one new campaign. No claim is made that physical footprint overshoots by only one logical transaction quantum.

Manual deletion is backend capability in this change and UI workflow in the next. It rejects an active or read-leased session, requires an explicit confirmation token bound to the exact session and current revision, and may tombstone a pinned closed session only when that exact confirmed revision remains current. Physical removal then uses the same bounded reclaimer.

### 6. Queries use short reader turns, append-only snapshot bounds, and leases

`ViewerEventQuery` supports:

- one recording-session scope, one or more device sessions, App/Bundle correlation, and direction;
- exact or prefix Event type, priority, Viewer receive-time range, terminal/gap/drop presence;
- literal full-text terms over Event type and canonical content JSON;
- JSON path predicates for existence, scalar equality, and text containment.

Different dimensions combine with AND. Multiple selected values within one dimension combine with OR. JSON predicates are individually ANDed; one predicate may contain an OR-list of scalar values. Search text is at most 512 UTF-8 bytes, rejects NUL and disallowed control characters, normalizes a search-only copy to Unicode NFC, splits into at most 32 literal terms, doubles embedded FTS5 quote characters, quotes every term, and joins them with explicit AND. Raw FTS operators are never accepted. A query contains at most 32 predicates and 16 selected device sessions.

JSON paths are at most 256 UTF-8 bytes and 16 components and use a closed grammar of root `$`, dot-name components, and nonnegative array indexes. Paths and comparison values are always SQLite parameters. Equality accepts null, Boolean, signed integer, finite number, or string; arrays and objects remain detail values, not V1 equality operands. Text containment applies only to a JSON string and compiles to `instr(value, parameter) > 0`, so `%`, `_`, and backslash remain literal. Event type exact values use validated equality; prefix uses a validated Event-type prefix and binary `substr(type, 1, length(parameter)) = parameter`, never `LIKE`. User input never becomes a SQL identifier, collation, ordering fragment, function name, or raw expression.

Pages contain 1 through 200 summaries, default 100. The first page acquires one recording read lease, captures upper `AUTOINCREMENT` IDs for Events, recording/device versions, disposition transitions, gaps, and drop samples, and stores the relevant bounds in a cursor with the normalized query fingerprint, lease token/expiry, Viewer monotonic order key, tie-break Event row ID, and direction. At most eight query leases exist. A lease has a 60-second idle and 10-minute absolute lifetime; cleanup/manual deletion skips it, and an expired/stale cursor fails closed and requests refresh.

Because Events and every membership-changing outcome are append-only, later pages select the latest transition/sample at or below the frozen table bounds. New inserts/transitions do not enter the traversal. Queries use explicit forward/backward keyset inequalities over `(viewerMonotonicNanoseconds, eventRowID)`, reverse only the returned page when required, and never use `OFFSET`. Equal monotonic samples remain stable through row ID.

The closed query compiler drives a recording/time/row-ID covering index and uses bounded existence probes for FTS/JSON predicates. Approved query/export plans SHALL NOT contain an unbounded temporary B-tree/sort over Event or metadata tables; deterministic `EXPLAIN QUERY PLAN` fixtures gate every compiler shape. Every page uses a short read transaction with a fixed VM-step and 250-ms execution budget; budget exhaustion returns a safe refine-query result rather than monopolizing the reader. Cancellation is generation-bound and returns no partial page. Event detail requires exact row ID plus recording scope and the same frozen bounds when loaded from a traversal.

One bounded latest-only commit notification reports at most 32 internal changed-recording row IDs, the new upper Event row ID, and store status. Coalescing unions only those bounded IDs, keeps the greatest row bound and latest status, and contains no Event type, content, peer identity, query text, SQL, or result array. The values remain available only to the trusted in-process refresh consumer. Description, interpolation, reflection, presentation, and logs are content-free and expose neither row identity. The later explorer uses the retained values to rerun its active query.

### 7. JSON export streams frozen append-only bounds under one finite lease

`ViewerJSONExporter` accepts either one complete recording session or one validated query. It acquires the single global export lease for that recording and captures upper AUTOINCREMENT row IDs for base device sessions, installation aliases, Events, recording/device versions, transitions, gaps, drop samples, and annotation versions. It writes a schema-version-1 root object containing `session`, `devices`, `events`, `gaps`, and `annotations`; recording metadata is one bounded row and device metadata remains paged at the frozen row-ID bounds. Stable alias ordinals are display values only and never act as snapshot bounds, so a lower logical ordinal committed after lease capture cannot enter the export. Cleanup/manual deletion rejects a leased recording. The lease expires after 60 minutes; expiry or source inconsistency cancels export safely.

Each Event is encoded and written individually from short bounded read pages on the dedicated export connection. Each page has a fixed VM-step and one-second execution budget, ends its read transaction before file output/yield, and honors the append-only upper bounds. It therefore pins no long SQLite snapshot/WAL while the writer continues. Export memory is bounded by one Event, one 200-row page, one metadata page, and a 64-KiB output buffer.

No Swift alias dictionary is built. Each logical installation receives a recording-local ordinal in `installation_aliases` when first durably admitted, and each exact device-session context receives a stable ordinal before persistence. Export uses `device-<installationOrdinal>` only for the peer installation identity shared across reconnects and `connection-<deviceSessionOrdinal>` only for an exact device-session row. Event rows reference both fields where applicable. Complete export across arbitrarily many sequential reconnects therefore has unambiguous aliases and constant alias memory. A complete session and filtered export share the query compiler, so filters cannot diverge from search semantics.

Export preserves Event ID, type, validated content, App wall creation date, Viewer wall receive/admission date, direction, priority, sequence, causality, local disposition, and safe App metadata. It substitutes `device-N` for installation identity and `connection-N` for exact device-session identity. It omits raw installation IDs, Viewer installation ID, internal connection IDs, exact session epochs, endpoints, pairing code, Bonjour data, requested/effective policy values, queue keys, certificates, Keychain selectors, raw frames, SQL paths, and internal errors.

The exporter opens the parent directory once with no-follow semantics, creates an owner-only temporary leaf relative to that descriptor, and retains the original temporary descriptor through flush and the commit seal. It validates regular-file type, owner, mode, link count, temporary inode, and parent-directory identity before one descriptor-relative rename, then synchronizes the same parent descriptor where supported. Cancellation or any leaf, hard-link, or parent substitution before the seal removes temporary state and preserves the prior destination. The caller supplies an already-authorized URL; this change stores no security-scoped bookmark.

Export files are ordinary unencrypted JSON outside Viewer quota, retention, cleanup, and sandbox control after the user selects a destination. Deterministic aliases are pseudonyms, not redaction: Event content and App metadata may still identify devices, people, accounts, or secrets, and destination providers may sync or back up the file. This change requires operator documentation and bounded export-preflight disclosure metadata for the next UI; the actual export selection/confirmation surface remains in `viewer-event-explorer-control`.

### 8. Storage UI is operational but history exploration remains later

The application model owns one `ViewerStoragePresentationModel` fed by latest-only safe status. A native Settings scene exposes capacity and `historyRetention` editing with explicit units and validation. It shows current usage, oldest Event, pinned usage estimate, estimated retained duration, current state, last cleanup result, and actions for cleanup and safe retry.

No Event content, type, search term, installation ID, database path, SQL error, or export destination enters the presentation snapshot, logs, interpolation, reflection, or accessibility values. Safe states use closed English labels such as Available, Capacity Paused, Write Failed, and Unavailable.

Pin/unpin, manual-delete confirmation, search controls, history lists, export selection, timeline rendering, and payload detail are intentionally deferred to `viewer-event-explorer-control`, which consumes the internal store APIs completed here.

Recording names are single-line, at most 80 Unicode scalars and 120 UTF-8 bytes, and reject every control character. Notes and individual annotation versions are at most 4,096 Unicode scalars and 16 KiB UTF-8; they permit tab and line feed but reject NUL and every other control character. These exact limits apply before database admission and export.

### 9. Shutdown owns a finite flush without holding the UI open forever

The runtime creates the stable logical recording context before it accepts device handoffs and materializes it only when durable admission succeeds. On shutdown, the session manager stops transfer and closes every device context first, then offers the recording close through reserved structural capacity and asks ingress to flush its already-accepted finite prefix. The existing cleanup receipt may outlive the one-second application UI wait, so SQLite ownership is not released early merely to close the window.

Every journal callback carries the logical runtime generation that created it. If a replacement window/runtime starts while the prior cleanup receipt is still running, the replacement remains explicitly nondurable until the prior generation closes its coordinator and a fresh coordinator recovers the replacement context. Late callbacks and repeated cleanup from the prior generation are ignored; they cannot attach the replacement to the old recording or close the replacement store.

The store flush has a fixed observation/byte bound because ingress is bounded. Runtime end first invalidates maintenance recovery publication and dirty successors, then waits for the serial maintenance owner to quiesce before the single terminal ingress flush begins. An already-running bounded campaign may finish before that barrier; no campaign or successor may overlap or follow the flush. The flush performs no cleanup scan after terminal failure and creates no retry loop. A successful flush checkpoints the finite committed work and closes the connection. A failed flush records one safe local status where possible, releases statements/connection/Tasks, and completes cleanup; the app is not kept alive indefinitely.

## Risks / Trade-offs

- **System SQLite requires a small C wrapper.** The wrapper is Viewer-internal, pointer ownership is confined to one executor, and tests exercise every binding/step/finalize/rollback path. This avoids a new package dependency for a capability the platform already supplies.
- **The journal can lose records under disk pressure.** Network correctness wins. Loss is bounded and made explicit through coalesced gaps and safe status rather than blocking device sessions or growing memory.
- **FTS and JSON indexes increase disk use.** Quota uses a conservative deterministic Event reservation and separately reports allocated SQLite sidecars; filesystem safety checks prevent quota accounting from pretending disk is available.
- **Physical reclamation cannot be one whole-session transaction.** One atomic tombstone removes the entire recording from visible history, then bounded child/FTS transactions reclaim it without ever exposing a partial session.
- **The database contains potentially sensitive debug content.** Main/sidecar files stay owner-only in the app container, use SQLite secure delete as defense in depth, never sync intentionally, and V1 documents that neither logical retention nor export guarantees secure erasure or redaction.
- **Cross-device wall clocks are unreliable.** Current-session merge uses Viewer monotonic receipt order; original App time is preserved only as source metadata.
- **Search/export can race new Events.** Short read turns use leases and append-only upper bounds; no long transaction pins WAL, and an expired lease fails closed instead of silently changing membership.

## Migration Plan

This is schema version 1 and no previous Event database exists. Startup creates a fresh database only when the expected path is absent. Existing Keychain identities, pairing behavior, requested flow preferences, and nicknames are unchanged. Rollback leaves the database untouched and restores memory-only operation; an older Viewer does not open or delete the history file.

## Open Questions

None for this change. At-rest encryption, import, UI history workflows, timeline rendering, control composition, and performance projections remain explicit later work.
