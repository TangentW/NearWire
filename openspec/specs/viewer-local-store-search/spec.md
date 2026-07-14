# viewer-local-store-search Specification

## Purpose
TBD - created by archiving change viewer-local-store-search. Update Purpose after archive.
## Requirements
### Requirement: Viewer owns one local SQLite store with explicit schema and failure boundaries

The Viewer SHALL use the system SQLite library with exactly one serial writer connection, one serial interactive-query connection, and one serial export connection. Each connection SHALL confine every statement and pointer to its executor. Startup SHALL open only a migration writer on a serial off-MainActor executor, complete migration and in-transaction probes, close that connection, then open and probe a fresh normal writer before either read connection. The fresh writer and later readers SHALL use `temp_store=MEMORY` and an explicit 8-MiB cache target; the migration-only FILE-temp/32-MiB settings SHALL never be published. The store SHALL use schema version 2 with immutable recording/device bases, installation aliases, immutable Events, append-only recording/device/disposition/policy/drop/gap/annotation versions, store metadata, a transactional FTS5 index, and explorer indexes for scoped Event UUID lookup and gap diagnostics. Migration from schema 1 SHALL add only those bounded indexes in one writer transaction and SHALL rewrite no Event/content row. Startup SHALL validate JSON1, FTS5, foreign keys, expected tables/indexes, accepted plans, accepted connection settings, and accepted schema version before writes. An unknown newer schema, corruption, migration failure, or missing required SQLite feature SHALL fail closed without deleting or recreating data and SHALL NOT prevent the network listener or bounded live projection from operating.

The Application Support directory SHALL be mode `0700`. Main database, WAL, SHM, rollback-journal/migration, and export-temporary artifacts SHALL be regular nonsymlink owner-only files with mode `0600` and SHALL be inspected while WAL is active and after close. SQLite SHALL use defensive/trusted-schema restrictions, memory-only temporary storage for normal connections, and `secure_delete=ON` where supported. Schema-1 index migration MAY use disk-backed SQLite temporary sorting only through the system default VFS and the process-provided sandbox/private temporary directory after verifying that directory is current-user-owned, mode `0700`, and nonsymlink. NearWire SHALL NOT read or mutate SQLite/process-global temporary-directory state, environment variables, or install a custom VFS. SQLite-created sorter files SHALL contain only index keys, SHALL use the system delete-on-close lifecycle, and SHALL have no remaining process file descriptor after the migration receipt completes. Documentation SHALL describe retention and OS temporary-file reclamation as logical cleanup, not guaranteed erasure from WAL history, temporary storage, filesystem snapshots, or backups.

Schema-1 migration SHALL own one exact operation token, one index statement at a time, a 32-MiB SQLite page/cache target, and no application row array. Before beginning, checked arithmetic SHALL require both database and OS temporary volumes, once if identical, to have free capacity of at least `512 MiB + 6 * allocated(main database + WAL + SHM)`; unsafe temporary root, insufficient capacity, or overflow SHALL not begin a transaction. A progress callback at most every 10,000 VM instructions SHALL cancel on token invalidation or when either volume's remaining capacity falls below 256 MiB. The populated-fixture acceptance gate SHALL keep process-heap growth above the idle writer baseline at or below 128 MiB and acknowledge injected in-SQLite cancellation within 250 ms; total migration duration SHALL be diagnostic only. Viewer SHALL attempt automatically at most once per process and SHALL retry only after explicit Retry Storage or a later launch.

Migration status SHALL use only `Preparing history update`, numbered index phase, `Validating history update`, `Migration needs more disk space`, `Migration cancelled`, or `Migration failed`. While schema 1 is intact or migrating, persistence/query/export SHALL remain unavailable while networking/live presentation may continue. All indexes, plan/schema/feature probes, and `user_version=2` SHALL complete inside one transaction. The migration connection SHALL close after commit or rollback and zero sorter descriptors SHALL remain. On success, a fresh normal writer SHALL probe schema 2, `temp_store=MEMORY`, the 8-MiB cache target, hardening, features, indexes, and plans before two equally normal fresh readers open and availability publishes. Post-open failure SHALL close them and fail unavailable. Cancellation, termination, resource or injected failure SHALL roll back to probe-valid schema 1, close every SQLite sorter descriptor, publish no schema 2, and join cleanup before completion.

Read operations SHALL use short transactions with SQLite progress budgets. Every interactive-read operation SHALL have an enqueue-to-completion token. Generation-bound cancellation MAY call `sqlite3_interrupt` only while that exact token is active on that exact read connection and SHALL NOT interrupt a queued, completed, superseded, or following operation. Export cancellation SHALL remain exact to the export generation.

When journal insertion encounters an existing exact `(recordingID, deviceSessionID, direction, wireSequence)` row, equality SHALL use the same durable projection as live ingress: Event ID/type, canonical content JSON bytes, App-created time normalized once to nearest integer milliseconds since 1970, App monotonic time, priority, TTL, schema version, correlation/reply IDs, and initial disposition. Source/target/session epoch SHALL already be exact-session transport invariants and cannot reach journal insertion when mismatched. Session metadata, deterministic byte accounting, and the later observation's newly sampled Viewer receive times SHALL not participate. Equality SHALL be an idempotent no-op preserving the first accounting/receive values. A different compared field SHALL preserve the existing immutable row and return one typed content-free `journalConflict` outcome to the live projection without changing store availability. Equality SHALL compare fields/bytes rather than trust a hash alone. It SHALL NOT rewrite the row, create a second durable row, expose content, or convert an expected duplicate collision into generic corruption.

#### Scenario: First launch creates schema version 2

- **WHEN** the expected Application Support database does not exist
- **THEN** Viewer creates schema version 2 and every sidecar/temporary artifact under the owner-only nonsymlink policy in one migration transaction
- **AND** no SQLite dependency is added to Core, SDK, the root package manifest, or the podspec

#### Scenario: Schema version 1 is opened

- **WHEN** a valid schema-1 store is opened after this change
- **THEN** the off-MainActor migration preflights headroom, exposes bounded safe progress, and one writer transaction adds the scoped Event UUID and gap-diagnostic indexes, probes final plans/schema, and sets version 2 without rewriting Event/content rows
- **AND** success closes the migration writer and publishes only a freshly probed memory-temp/8-MiB-cache normal pool, while cancellation, termination, unsafe OS temporary storage, insufficient resources, or failure closes every sorter descriptor, rolls back to intact schema 1, and leaves persistence/query/export unavailable rather than partially upgraded or retrying in a loop

#### Scenario: Existing schema is unsupported

- **WHEN** the database reports an unknown newer schema version or fails integrity/schema validation
- **THEN** persistence, query, and export become unavailable with one closed safe category
- **AND** Viewer neither recreates the database nor terminates active network sessions

#### Scenario: Query cancellation races completion

- **WHEN** cancellation for operation A arrives after A completes and operation B becomes active
- **THEN** A's token is a no-op and only a cancellation carrying B's exact token may interrupt B
- **AND** the following operation observes no stale interrupt or leaked statement

### Requirement: Viewer automatically records runtime and device-session lifecycle

Each live Viewer runtime SHALL create one stable logical recording context before device transfer begins. A durable recording row SHALL exist only after its parent admission commits. A durable device row SHALL exist only after that recording and the exact device-start admission commit in causal order; Event/sample rows SHALL require the durable device parent. Pairing refresh SHALL preserve the context. Shutdown SHALL close durable device rows before the durable recording row through reserved structural capacity and bounded final flush. A later runtime SHALL use a new context while retaining prior history.

If storage is unavailable at start, Viewer SHALL keep networking live without claiming durable rows. A successful same-runtime retry SHALL materialize the original recording identity/time, one coalesced unavailable gap, and only device contexts still live; later Events become eligible after those commits. Queue admission alone SHALL NOT count as recovery. The missed-observation aggregate SHALL remain owned by a generation-bound in-flight claim until materialization and bounded gap ownership complete; failure SHALL merge the claim with observations received during the attempt without overflow. Devices that started and ended entirely during the outage SHALL be represented only by the gap.

Every successful database reopen SHALL reconcile exactly one prior recording group per transaction and at most eight immediate group turns. One group SHALL contain at most 16 open device children; the transaction SHALL append every child interruption version before the parent interruption version and commit all or none. More children SHALL fail as schema corruption. Cleanup SHALL not select an unreconciled open parent. A new durable recording SHALL wait for zero prior open groups; if the turn bound is exhausted first, networking MAY continue non-durably until a later explicit retry.

#### Scenario: Several devices share one Viewer runtime

- **WHEN** four Apps connect, disconnect, and reconnect while one Viewer window remains live
- **THEN** all logical connections belong to one recording context and each durably admitted exact connection has one distinct device-session row

#### Scenario: Viewer reopens

- **WHEN** the last window closes cleanly and a later window starts listening
- **THEN** the earlier recording session is closed and queryable
- **AND** the later runtime uses a new recording session without deleting prior history

#### Scenario: Store becomes available mid-runtime

- **WHEN** Viewer started without storage and an explicit retry succeeds after one device ended and another remains live
- **THEN** the recording parent and live device materialize in causal order with a partial-history marker and one bounded unavailable gap
- **AND** the ended device and missing Events are not reconstructed as false complete rows

#### Scenario: Admitted recovery work fails before materialization

- **WHEN** Viewer admits same-runtime recovery work but recording or live-device materialization fails
- **THEN** Viewer remains unavailable and does not publish successful recovery
- **AND** the exact claimed missed-observation aggregate remains available to one later explicit retry

#### Scenario: Prior process left open rows

- **WHEN** startup finds durable recording/device rows left open by crash or failed final flush
- **THEN** bounded reconciliation closes them idempotently before admitting the new recording
- **AND** no orphan remains permanently protected as active

### Requirement: Validated bidirectional Event outcomes are journaled without becoming protocol authority

For App-to-Viewer traffic, Viewer SHALL offer one immutable Event-commit observation only after frame-wide route, schema, sequence, and receiver-deadline validation commits. Its unique journal key SHALL be `(recordingID, deviceSessionID, direction, wireSequence)`; peer Event UUID SHALL remain content and SHALL NOT be assumed unique across a connection. An immediately expired/overflow-dropped record SHALL carry that terminal admission disposition; a buffered record SHALL later receive at most one sequence-keyed append-only terminal transition of `consumerAccepted`, `expired`, `overflowDisplaced`, or `sessionEnded`. Duplicate-identical transitions SHALL be idempotent, and conflicting terminal transitions SHALL fail only the store. If a transition is lost, a gap SHALL explain incomplete journal state and the Event SHALL remain explicitly nonfinal. Invalid frames SHALL create no Event row.

For Viewer-to-App traffic, Viewer SHALL journal only Events whose complete frame has been synchronously accepted by the secure mailbox and whose sequence/queue/token transaction committed. A stored downlink SHALL be labeled transport-admitted and SHALL NOT claim peer receipt, processing, acknowledgement, or delivery.

Journal admission and every persistence callback SHALL be unable to modify protocol sequence, queues, tokens, mailbox ownership, timeout arbitration, or terminal state. Storage unavailability SHALL NOT close a device connection.

#### Scenario: Valid uplink is locally overflow-dropped

- **WHEN** a structurally valid contiguous uplink Event commits sequence but the live delivery queue selects it or another Event for overflow
- **THEN** the journal records the committed Event and exact local disposition
- **AND** storage outcome cannot change the wire sequence result

#### Scenario: Buffered uplink later reaches a terminal outcome

- **WHEN** a previously committed buffered Event is later consumer-accepted, expired, displaced by another enqueue, or cleared by session end
- **THEN** Viewer appends one idempotent terminal transition without rewriting the immutable Event
- **AND** a later conflicting transition changes no protocol or durable Event content

#### Scenario: Downlink mailbox rejects a candidate

- **WHEN** a queued downlink Event is expired, route-dropped, fails encoding, or is rejected by mailbox backpressure
- **THEN** no sent Event row is journaled and the next sequence remains unchanged

#### Scenario: Downlink frame is admitted

- **WHEN** one Event or batch frame enters the secure mailbox atomically
- **THEN** its committed records are journaled once as transport-admitted
- **AND** later transport failure does not rewrite the journal as delivered or uncommitted

### Requirement: Store ingress and write transactions are finite and nonblocking

Viewer SHALL offer Event/sample/transition observations through a lock-protected ingress bounded by count and bytes. Defaults SHALL be 4,096 observations and 32 MiB; hard maxima SHALL be 8,192 observations and 64 MiB. A separate fixed structural lane SHALL retain at most 36 coalesced recording/device start/close/reconcile values and SHALL be unavailable to Event traffic. At most one writer drain plus one dirty successor SHALL exist.

One normal transaction SHALL write at most 256 observations or 4 MiB. One single Event observation MAY instead use one-record oversize mode up to a 20-MiB hard reservation. Session setup SHALL prove the negotiated maximum journal observation fits that bound and default ingress. An impossible larger observation SHALL become a gap before admission and SHALL NOT block later ingress. No physical SQLite/WAL amplification bound SHALL be inferred from the logical transaction quantum.

Ingress admission SHALL use the record's already-computed deterministic byte count plus checked fixed metadata reservation and Swift copy-on-write value ownership. It SHALL perform no JSON encoding, content traversal, SQLite binding, or deep copy on the protocol executor; those operations SHALL occur only after admission on the writer executor.

Event ingress overflow, capacity pause, unavailable storage, or a write-failed state SHALL coalesce one bounded gap aggregate instead of blocking protocol executors or creating one task/value per dropped journal record. Structural close state SHALL use its reserved lane or next-open reconciliation. A transaction failure SHALL roll back its entire prefix, retain at most the already-bounded prefix for one explicit retry boundary, stop automatic polling, and expose only a closed safe status.

#### Scenario: Database is slower than sixteen devices

- **WHEN** concurrent committed Events fill the bounded ingress faster than SQLite can drain it
- **THEN** the ingress never exceeds its count or byte limit and owns at most one drain plus one successor
- **AND** excess journal observations coalesce into a gap while every device protocol executor continues

#### Scenario: Write transaction fails

- **WHEN** an injected busy, full-disk, I/O, or index failure occurs before commit
- **THEN** the whole transaction rolls back and no partial Event/index prefix is visible
- **AND** Viewer schedules no recurring retry until an explicit retry or relevant data/configuration change

#### Scenario: Maximum legal Event is journaled

- **WHEN** one observation is above 4 MiB but at or below the proven 20-MiB hard reservation
- **THEN** it uses one-record oversize mode without splitting Event/FTS atomicity or blocking the head
- **AND** equal/below/above boundary tests prove exact ingress and transaction behavior

#### Scenario: Event ingress is full when a device closes

- **WHEN** all Event capacity is occupied and a durable device/recording close occurs
- **THEN** reserved structural ownership preserves the bounded close or startup reconciliation repairs it
- **AND** Event traffic cannot leave a permanently active orphan row

### Requirement: Storage preferences have bounded 3 GiB and seven-day defaults

Viewer SHALL persist one versioned storage preference with a default capacity of exactly 3 GiB and default `historyRetention` of exactly seven days. Capacity SHALL accept 64 MiB through 1 TiB, and history retention SHALL accept one through 3,650 days. Corrupt, oversized, unknown-version, nonintegral, or out-of-range values SHALL recover to defaults. UI, documentation, and APIs SHALL distinguish `historyRetention` from Event TTL.

#### Scenario: Preferences are absent or corrupt

- **WHEN** Viewer first runs or its bounded preference value cannot be validated
- **THEN** capacity is 3 GiB and history retention is seven days
- **AND** no Event, query, database path, or effective flow policy is written to `UserDefaults`

#### Scenario: User changes storage limits

- **WHEN** the user saves valid capacity and retention values
- **THEN** the store applies them, runs one maintenance decision, and publishes updated safe status

#### Scenario: A recovery-eligible settings edit is superseded

- **WHEN** an improving settings edit captures recovery authority and a newer edit reverts or replaces it before recovery publication
- **THEN** the older maintenance campaign cannot reopen automatic writes
- **AND** only a recovery-eligible decision bound to the latest settings revision may publish successful recovery

### Requirement: Cleanup is transactional, whole-session, and protection aware

Maintenance SHALL run at startup, after settings change, after a recording closes, after a bounded committed-byte threshold, and through at most one replaceable 15-minute wake while a runtime is active. One trigger SHALL own at most eight immediate turns. One turn SHALL perform exactly one bounded mutation: atomically tombstone at most 32 closed unpinned/unleased recording sessions, reclaim at most 1,024 child rows/4 MiB, or perform one checkpoint/free-page step, then yield. It SHALL NOT create more than one maintenance task plus one dirty successor or automatically retry a failed turn.

Quota selection SHALL use overflow-safe schema-owned accounting. Each Event SHALL reserve `2 * deterministicCanonicalEventBytes + 1 KiB`; other row kinds SHALL use fixed checked reservations. In each logical-delete transaction Viewer SHALL first mark retention-expired eligible sessions, then if usage is above capacity mark oldest eligible sessions until quota-accounted visible usage is at or below 85% or the turn/campaign bound is reached. Every selected mark and quota subtraction SHALL commit together or none SHALL.

Active, pinned, and read-leased recordings SHALL never be selected. Tombstoned recordings SHALL disappear atomically from all visible history. A normal physical reclaim SHALL remove at most 1,024 child rows or 4 MiB including matching FTS rows. One oversize Event at the reclaim head MAY use one-record Event-plus-FTS mode up to a 41-MiB hard quota reservation so every legal 20-MiB journal observation is reclaimable. A larger/impossible row SHALL fail safely without permanently blocking later tombstones. Failure SHALL roll back only the current reclaim batch and leave the whole recording logically deleted, never partially visible. Checkpoint/free-page failure SHALL NOT select more sessions or claim logical rollback.

If eligible sessions are exhausted above 85% but at/below 100%, Viewer SHALL remain writable and report low-water not reached. Above 100%, protected data, lease ownership, or a bounded campaign that cannot make enough progress SHALL pause writes until a later explicit/bounded trigger. Status SHALL distinguish quota-accounted usage from allocated database/WAL/SHM footprint. A separate volume-available-capacity guard with a 64-MiB floor SHALL prevent writes from exhausting physical disk; no physical overshoot claim SHALL be derived from logical batch bytes.

#### Scenario: Retention and capacity both require cleanup

- **WHEN** expired eligible sessions exist and usage also exceeds capacity
- **THEN** retention tombstones run first and remaining oldest eligible sessions are selected toward the 85% quota low-water mark within bounded campaign turns

#### Scenario: Protected data fills the quota

- **WHEN** active plus pinned data prevents usage from returning within capacity
- **THEN** Viewer deletes none of that protected data, pauses new Event writes, keeps live connections operating, and exposes actionable safe status

#### Scenario: Cleanup mutation fails

- **WHEN** any selected session deletion, cascade, or FTS mutation fails
- **THEN** the current logical-selection or physical-reclaim transaction rolls back completely
- **AND** no recording is partially visible even if an earlier tombstone awaits later physical reclamation

#### Scenario: One recording contains very large history

- **WHEN** cleanup selects a closed recording containing millions of Event/FTS rows
- **THEN** one atomic tombstone removes the complete recording from visible history
- **AND** bounded reclaim transactions yield and can resume without an unbounded executor turn

### Requirement: Pin, metadata, and manual deletion operations are revision safe

Viewer SHALL provide internal operations to rename, annotate, pin, and unpin a recording session using bounded validated text. A recording name SHALL be single-line, contain at most 80 Unicode scalars and 120 UTF-8 bytes, and reject controls. A note or annotation version SHALL contain at most 4,096 Unicode scalars and 16 KiB UTF-8, allow only tab/line feed among controls, and reject NUL. Annotation changes SHALL append versions rather than rewrite export snapshot history.

Manual deletion SHALL reject an active or read-leased recording and require an explicit confirmation token bound to the exact closed session ID and current revision. A stale token SHALL delete nothing. A pinned closed session MAY be tombstoned only by a matching explicit confirmation and SHALL use the bounded physical reclaimer.

#### Scenario: Automatic cleanup sees a pinned session

- **WHEN** an old pinned session is beyond retention and capacity cleanup runs
- **THEN** that session and all of its children remain intact

#### Scenario: Session changes after confirmation

- **WHEN** a rename, annotation, pin change, or other revision mutation occurs after a delete confirmation is issued
- **THEN** using the stale confirmation deletes nothing

### Requirement: Full-text and JSON path queries are validated and indexed

Viewer SHALL query the same persisted Events for live refresh and history. Different filter dimensions SHALL combine with AND and selected values within one dimension SHALL combine with OR. V1 SHALL support recording/device/App/Bundle scope, exact or prefix Event type, direction, priority, Viewer receive-time range, literal full-text terms over type and content, safe JSON path existence/scalar-equality/string-containment predicates, and gap/drop presence.

Search text SHALL be at most 512 UTF-8 bytes, reject NUL/disallowed controls, normalize a search-only copy to NFC, and compile at most 32 individually quoted/escaped literal FTS5 terms joined with explicit AND rather than accept raw FTS syntax. A query SHALL contain at most 32 predicates and 16 device-session selections. JSON paths SHALL use a closed root/dot-name/nonnegative-index grammar bounded to 256 UTF-8 bytes and 16 components. Paths, terms, and values SHALL be bound parameters and SHALL never become raw SQL, identifiers, functions, collations, or ordering fragments.

Event-type prefix matching SHALL validate the Event-type prefix and use binary `substr` equality, never `LIKE`. JSON string containment SHALL use `instr` with a bound string. Percent, underscore, backslash, quote, FTS operators, SQL comments, and Unicode normalization cases SHALL therefore have specified literal/rejection semantics rather than wildcard behavior.

#### Scenario: Combined query matches live and historical rows

- **WHEN** a query selects devices, an Event-type prefix, direction, priority, text terms, and JSON predicates
- **THEN** the same compiled query semantics apply to newly committed and older Events
- **AND** no network replay or request to an App is needed

#### Scenario: Query input resembles SQL or FTS syntax

- **WHEN** search text, JSON path, or comparison text contains quotes, operators, comments, wildcard syntax, or control characters
- **THEN** it is safely literalized or rejected by the closed validator and cannot alter the SQL plan

### Requirement: Event results use stable bounded keyset pagination

Event pages SHALL contain 1 through 200 summaries, default 100. The first page SHALL acquire one recording read lease and freeze upper `AUTOINCREMENT` IDs for Events, recording/device versions, disposition transitions, gaps, and drop samples. Continuation cursors SHALL bind the normalized query fingerprint, every relevant upper bound, lease token/expiry, Viewer monotonic ordering key, tie-break Event row ID, and direction. Event and related membership history SHALL be append-only, so later pages can select values at or below those bounds without a long SQLite snapshot.

At most eight query leases SHALL exist. Each SHALL expire after 60 seconds idle or 10 minutes absolute; cleanup/manual delete SHALL skip it, and an expired/stale cursor SHALL fail closed. Each page SHALL use a short read transaction, fixed VM-step and 250-ms execution budget, and explicit forward/backward keyset inequalities over `(viewerMonotonicNanoseconds, eventRowID)`. The compiler SHALL drive a recording/time/row-ID covering index and SHALL reject any supported query/export plan whose `EXPLAIN QUERY PLAN` requires an unbounded temporary B-tree/sort over Event or metadata tables. It SHALL NOT use SQL `OFFSET`, reuse deleted row IDs, or materialize all matching rows. New writes/transitions SHALL not enter an existing traversal. Exact detail loading SHALL require row ID, recording scope, and frozen bounds when traversal consistency is requested.

#### Scenario: New Events arrive during pagination

- **WHEN** page one is returned and more matching Events commit before page two
- **THEN** page two continues the leased append-only snapshot without duplicates, membership changes, or newly inserted rows

#### Scenario: Cursor is reused with another query

- **WHEN** a cursor fingerprint or recording scope does not match the current query
- **THEN** Viewer rejects it with a closed query error and performs no fallback offset query

#### Scenario: Cleanup or transition races pagination

- **WHEN** cleanup targets the leased recording or a new disposition/gap/drop transition commits after page one
- **THEN** cleanup skips the lease and later pages use only transition/sample IDs at or below the frozen bounds

#### Scenario: Query exceeds its work budget

- **WHEN** a broad JSON predicate exhausts its VM-step or 250-ms page budget before returning a complete page
- **THEN** Viewer returns one safe refine-query result, releases the short transaction, and leaves writer progress available

### Requirement: JSON export streams a complete session or frozen filtered result

Viewer SHALL export schema-version-1 JSON containing session, devices, Events, gaps, and annotations for either one complete recording session or one validated frozen query. One global export lease SHALL protect the exact recording from cleanup/manual delete and SHALL expire after 60 minutes. Export SHALL freeze upper AUTOINCREMENT row IDs for base device sessions, installation aliases, Events, recording/device versions, transitions, gaps, drop samples, and annotation versions. Recording metadata SHALL be one bounded row and device metadata SHALL be paged at those row-ID bounds. Stable alias ordinals SHALL be display values only, not snapshot bounds. Export SHALL use short read transactions on the dedicated export connection with a fixed per-page VM-step/one-second budget, share query semantics with search, encode one bounded record/page at a time, and SHALL NOT hold a long SQLite snapshot or load the complete result into memory.

Each logical installation and exact device-session context SHALL receive distinct stable recording-local ordinals before/during durable admission. Export SHALL use `device-N` only for installation identity across reconnects and `connection-N` only for an exact device-session row, derive both directly from paged stored ordinals, and SHALL NOT build an in-memory alias dictionary even with arbitrarily many sequential reconnect rows.

Device and installation identities SHALL be replaced by deterministic export-local aliases. Export SHALL preserve validated Event content and safe analysis metadata but omit raw installation IDs, Viewer identity, connection IDs, exact session epochs, endpoints, requested/effective policy values, pairing/Bonjour data, TLS/Keychain material, queue keys, raw frames, database paths, and internal errors. Output SHALL be ordinary unencrypted JSON.

The exporter SHALL write an owner-only nonsymlink temporary sibling, flush and close it, atomically replace the requested destination only on success, and synchronize the parent directory where supported. Cancellation or failure at any pre-commit file/query phase SHALL remove temporary state and preserve any existing destination.

Operator documentation and bounded export-preflight disclosure metadata SHALL state that aliases are pseudonyms rather than redaction, Event/App content may identify secrets or people, output is unencrypted, export files are outside Viewer quota/retention/cleanup, and a destination provider may sync or back them up. The Event Explorer SHALL expose Complete Recording and Current Filtered Result only after showing that disclosure; it SHALL invoke the native save panel only after acknowledgement, own that selection through one cancellable lifecycle identity, weakly capture the explorer, make delayed responses after flow/runtime cancellation no-ops, SHALL NOT persist the selected destination, and SHALL report completion only after the export commit succeeds.

#### Scenario: Large filtered export

- **WHEN** a filter matches millions of Events across several devices
- **THEN** export memory remains bounded by one Event, one 200-row data/metadata page, and a 64-KiB output buffer with no alias map
- **AND** the output contains exactly the frozen query result in Viewer receive order

#### Scenario: Export is cancelled

- **WHEN** cancellation occurs after some rows are written
- **THEN** no partial destination replaces the prior file and the temporary file is removed

#### Scenario: Cleanup and sustained writes race export

- **WHEN** one large export runs while other recordings receive writes and cleanup targets its source
- **THEN** short read turns do not pin WAL, writer turns continue, and cleanup skips the finite export lease
- **AND** the exported source is frozen by append-only upper bounds until completion, cancellation, or lease expiry

#### Scenario: Operator has not accepted disclosure

- **WHEN** the operator requests export but cancels or has not accepted the current disclosure
- **THEN** Viewer opens no save panel, acquires no export lease, and writes no file

### Requirement: Storage status and settings expose no Event data

Viewer SHALL publish latest-only safe storage status and provide a native settings surface for capacity and `historyRetention`. Status SHALL distinguish deterministic quota-accounted live bytes from allocated database/WAL/SHM footprint and SHALL include capacity, oldest retained Event date, pinned quota estimate, estimated retained duration, current state, and last cleanup category. It SHALL not include Event type/content, search text, installation identity, database path, SQL text/error, raw peer values, or export destination. An internal latest-only refresh value MAY retain at most 32 recording row IDs and one upper Event row ID for a trusted in-process query consumer, but every description, interpolation, reflection helper, presentation value, and log SHALL omit those identities.

The settings surface SHALL NOT add Event history rows, timeline/detail rendering, search/filter controls, pin/delete history browsing, export selection, control composition, or performance charts in this change.

#### Scenario: Capacity pause is shown

- **WHEN** protected data exhausts capacity
- **THEN** settings explain that recording is paused and identify capacity increase, unpin, or manual deletion as recovery actions
- **AND** no sensitive Event or identity value appears in the message or accessibility tree

#### Scenario: A populated refresh value reaches diagnostics

- **WHEN** the internal latest-only refresh value contains nonzero recording and Event row IDs
- **THEN** its trusted consumer receives the exact bounded refresh values
- **AND** generic description, interpolation, reflection, presentation, and logs reveal neither row identity

### Requirement: Shutdown performs a finite owned flush

Runtime shutdown SHALL stop device transfer and complete logical device terminal observations before offering the durable device/recording closes through reserved structural capacity and flushing the already-admitted bounded ingress. It SHALL invalidate maintenance recovery publication and dirty successors, then establish maintenance-queue quiescence before the one terminal flush begins. No maintenance campaign or successor SHALL overlap or follow that flush. Store cleanup MAY outlive the application's bounded UI wait through the existing cleanup receipt, but it SHALL own no unbounded queue, maintenance campaign, retry loop, or indefinite window blocker. Success SHALL close statements and all three connections after the finite flush. Failure SHALL release all store resources and complete cleanup without claiming unwritten rows were persisted; next-open reconciliation SHALL close any durable orphan.

#### Scenario: Window closes with pending store work

- **WHEN** the last window closes while bounded observations remain in ingress
- **THEN** device cleanup wins first, the exact finite prefix receives one flush attempt, and resource ownership survives the UI timeout if necessary
- **AND** maintenance is quiescent before the flush and no invalidated dirty successor performs a later writer turn
- **AND** the application is not held open by recurring cleanup or retry work

### Requirement: Store exposes bounded explorer catalogs, diagnostics, detail, and mutation facades

ViewerStoreRuntime SHALL own and dynamically route every application-facing catalog/query/detail/gap/causality/mutation/export request. The application SHALL NOT retain coordinator services. Each request and lease SHALL bind to the immutable coordinator generation that created it and share that generation's delivery-validity state. Traversal release, query replacement, tail page, and gap operations SHALL retain their exact token, and a successor stage SHALL require its predecessor's same still-published generation. Replacement SHALL invalidate predecessor delivery before successor publication, seal that generation, reject new work, cancel and join its exact bounded operations, release leases through the originating registry, and close it before publishing replacement availability. A predecessor callback that already claimed client delivery SHALL retire its exact controller work without applying mutable presentation state or launching successor-generation work. The sole exception is an exact content-free export terminal receipt: pre-commit cancellation or Store replacement remains a failure, while success after atomic destination replacement remains authoritative to the still-live controller. Late traversal or content work SHALL fail with one closed `storeReplaced` presentation result and SHALL NOT attach to the replacement implicitly.

One non-MainActor query arbiter SHALL be the sole mutable owner of a ViewerEventTraversal and its refreshed lease. Page, detail, gap, causality, and filtered-export scope operations SHALL serialize through it. Source replacement SHALL end that traversal once. Filtered export SHALL receive an immutable query/snapshot scope and acquire its own export lease; it SHALL NOT share or refresh the interactive query lease concurrently. Catalog requests share the serial reader through distinct operation tokens but SHALL NOT touch the traversal.

Viewer SHALL expose internal recording and device catalogs through that reader. Recording pages SHALL contain 1 through 100 rows, default 50, and use immutable descending recording row ID. A recording cursor SHALL bind store generation, recording/version/tombstone upper row IDs, change generation, fingerprint, direction, and row-ID key. Device pages SHALL contain 1 through 200 rows, default 100, and bind device/version upper row IDs while using connection ordinal plus row ID. Any relevant store change SHALL invalidate and restart a catalog; exact no-omission continuity is promised only within one unchanged frozen traversal. Catalog rows SHALL contain bounded names, state, pin/revision, start/end, device aliases, App/Bundle hints, and gap/drop indicators but SHALL contain no Event content, raw installation identifier, connection UUID, path, SQL, or underlying error. Neither catalog SHALL use `OFFSET`, a long transaction, mutable activity ordering, or complete-history materialization.

New durable device materialization SHALL store the exact admission connection ID in the existing `DeviceSessions.logicalID` column so current transient and durable journal identities can reconcile without peer Event UUID. Pre-existing closed rows SHALL remain valid without migration because no current transient row can reference them. Explorer Event detail SHALL extend the existing frozen point lookup with exact device logical identity/aliases, origin monotonic time, TTL, schema version, correlation/reply IDs, and resolved disposition.

Gap pages SHALL bind the exact Event traversal lease/device filters/frozen gap upper row ID; contain 1 through 32 rows; select the latest revision at or below that bound; use stable `(recordingID, optional deviceSessionID, namespace, sequence)` identity; and traverse `(lastViewerWallMilliseconds, gapRowID)` in either direction. Causality lookup SHALL bind recording, exact device, lease, and frozen Event upper row ID; order candidates by durable row ID; read at most nine rows to return eight plus `hasMore`; expand reply-to before correlation breadth-first; and use durable row ID for the 32-node visited/cycle set. Repeated peer UUIDs SHALL remain ambiguous rather than becoming keys or false cycles.

Recording/device catalog, gap, and causality operations SHALL each use at most 2,000,000 VM steps and 250 ms, generation cancellation, short transactions, and plan gates that reject unbounded scan/sort/temp B-trees. Budget exhaustion SHALL return one fixed refine result and no partial complete page. Schema 2 SHALL add exactly `(recordingID, deviceSessionID, eventUUID, rowID)`, `(recordingID, lastViewerWallMs, rowID)`, and `(recordingID, deviceSessionID, lastViewerWallMs, rowID)` indexes. Catalog plans SHALL use the existing integer-primary-key and recording/version/tombstone/device unique indexes; a failed exact plan gate SHALL require a reviewed artifact amendment rather than an opportunistic source-only index.

An all-device gap page SHALL use the all-device gap-order index. A page scoped to 1 through 16 devices SHALL use at most 16 device index ranges plus the recording-level `deviceSessionID IS NULL` range and a bounded 17-lane merge for at most 32 results. Latest-revision lookup SHALL use the existing gap identity/revision unique index under the frozen gap upper row ID.

Recording rename/note/annotation/pin/delete and complete/filtered export facades SHALL preserve the existing validators, writer ordering, revision-bound confirmation, active/read-lease protection, finite export lease, and closed safe errors. The application dependency boundary SHALL expose only immutable Sendable models and operations, never a SQLite connection, statement, pointer, database path, SQL string/error, or raw filesystem phase.

#### Scenario: History contains more recordings than one page

- **WHEN** the operator scrolls beyond the first 50 recording rows
- **THEN** the next page continues by the exact immutable descending recording-row-ID keyset without duplicates or omissions inside the unchanged frozen traversal
- **AND** a relevant catalog change invalidates and restarts the cursor from page one, while no Event content or complete catalog is retained merely to paginate

#### Scenario: Peer Event ID is reused

- **WHEN** causality lookup finds several rows with the same Event UUID in one device session
- **THEN** it returns a bounded ambiguous candidate set rather than one arbitrary row
- **AND** the immutable Events and query traversal remain unchanged

#### Scenario: Store becomes unavailable during an explorer operation

- **WHEN** catalog, detail, gap, mutation, or export work fails safely
- **THEN** the operation returns one closed presentation category and releases its short transaction or lease
- **AND** no network session, raw error, SQL, or path is exposed or altered

#### Scenario: Coordinator is replaced during a read

- **WHEN** retry or sequential runtime reopen retires the coordinator generation that owns an explorer operation
- **THEN** the runtime cancels/joins that exact operation and releases its exact originating lease before close
- **AND** a synchronous successor rejection after predecessor validation carries no stale presentation update
- **AND** stale work cannot publish or retarget itself, while a new explicit request may use the replacement generation

### Requirement: Store exposes bounded candidate-scanned performance and gap traversal

The Store explorer gateway SHALL expose one forward-only internal traversal for a positive recording
row ID, positive exact device-session row ID, inclusive Viewer monotonic lower/upper bounds, frozen
Event/gap upper row IDs, Store generation, and opaque continuation. The continuation SHALL bind the
complete scope and exact last examined `(viewerMonotonicNanoseconds, eventRowID)` independently of
the last emitted row. Results SHALL order stably by that key.

The accepted existing device timeline index SHALL scan candidate metadata before residual exact-type
filtering. Each examined matching or nonmatching candidate SHALL advance the continuation. A turn
SHALL examine at most 4,096 candidates and emit at most 512 carriers. SQLite SHALL read type and
`length(contentJSON)` before content. Content longer than 65,536 UTF-8 bytes SHALL emit only identity,
length, and invalid marker. Eligible content SHALL copy only while aggregate copied bytes remain at
most 4,194,304; every carrier SHALL charge 512 fixed bytes and the page wrapper 4,096, for a
4,460,544-byte page maximum. If the next eligible row would cross bytes, the turn SHALL stop before
examining it. A zero-match turn SHALL return its advanced continuation; no row may skip, duplicate,
or livelock.

An injected monotonic clock and VM counter SHALL gate 50 ms and 5,000,000 instructions. Cancellation
is checked before work. Equality after an examined row yields at that row. VM/time exhaustion before
the first candidate SHALL return terminal work-limit failure rather than an unchanged continuation.
Host elapsed time SHALL be diagnostic only. The query arbiter SHALL own the traversal and finite
lease; cancellation, mode/range/source replacement, Store retry/reopen, and cleanup SHALL release it
once and SHALL not interrupt or retarget a successor.

The same frozen scope SHALL expose gap pages of at most 32 latest-revision exact-device/recording-wide
rows under its gap upper row ID and at most 128 detailed gaps to one projection. Store SHALL normalize
each row into one fixed 256-byte carrier containing only row/scope identity, a closed safe kind,
schema-2 Viewer wall interval, and applicability. Variable namespace, reason, and direction strings
SHALL not cross. A fixed 512-byte wrapper SHALL carry generic `hasMoreRows`, a saturating
performance-or-uncertain count, and `hasMoreApplicableGaps`, making each page at most 8,704 bytes.

Store SHALL classify the complete frozen matching gap metadata scope before deciding applicable
overflow, under the existing 2,000,000-VM-step, injected-250-ms, cancellation, and accepted-plan
gates. A hidden performance or uncertain row SHALL set `hasMoreApplicableGaps`; hidden irrelevant-only
rows SHALL set only `hasMoreRows`. If complete classification exhausts its budget, the returned page
SHALL set `hasMoreApplicableGaps` true regardless of its partial count, never claim classification
complete, and never reconnect a line. Store SHALL not fabricate monotonic time.

Normalization SHALL use case-sensitive ASCII exact/prefix comparison and map
`missingInitialEvent.*` to eventLoss; `storageUnavailable`,
`midRuntimeRetry`, `liveStart`, and `store*` to storageContinuity; `uplinkDisposition*`,
`dropJournal*`, and `policyJournal*` to controlContinuity; `deviceClose*` and `shutdownStructural*` to
lifecycleContinuity; and `coalescedOverflow` or unrecognized reasons to unknown. Direction SHALL map
`appToViewer`/`both` to performance, `viewerToApp` to irrelevant, and `unknown` or unrecognized input
to uncertain. Unknown kind or applicability SHALL remain conservative rather than being discarded.

Schema version SHALL remain 2. No performance table, derived JSON, trigger, index, database,
background backfill, or migration SHALL be added. Raw Events and gaps remain subject to existing
quota, retention, pin, deletion, export, secure-file, and cleanup behavior.

#### Scenario: Ordinary Events precede a matching snapshot

- **WHEN** 4,097 nonmatching Events precede one matching performance Event
- **THEN** the first empty turn advances exactly 4,096 examined keys and the next turn emits the snapshot once
- **AND** no returned-row cursor, time/VM boundary, or continuation retry can skip or duplicate it

#### Scenario: Aggregate page bytes fill

- **WHEN** the next at-most-65,536-byte snapshot would cross 4,194,304 copied content bytes
- **THEN** the page ends before examining it and the next page retries it under the same scope
- **AND** an oversized row returns only bounded metadata while raw JSON remains in Events

#### Scenario: Store generation changes between turns

- **WHEN** generation A attempts another turn after generation B is published
- **THEN** A is rejected and its exact traversal/lease is released once
- **AND** only an explicit fresh request may use B

#### Scenario: Generic pagination hides different applicability tails

- **WHEN** two 129-row scopes retain identical 128 irrelevant carriers but only one hidden tail is performance-applicable
- **THEN** both report `hasMoreRows` while only the applicable-tail receipt reports `hasMoreApplicableGaps`
- **AND** a classification budget failure cannot report the hidden tail as irrelevant-only
