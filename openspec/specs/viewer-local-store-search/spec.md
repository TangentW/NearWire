# viewer-local-store-search Specification

## Purpose
TBD - created by archiving change viewer-local-store-search. Update Purpose after archive.
## Requirements
### Requirement: Viewer owns one local SQLite store with explicit schema and failure boundaries

The Viewer SHALL use the system SQLite library with exactly one serial writer connection, one serial interactive-query connection, and one serial export connection. Each connection SHALL confine every statement and pointer to its executor. Startup SHALL open only the writer, complete migration and writer/schema probes, and accept the schema before opening either read connection. The store SHALL use a versioned schema with immutable recording/device bases, installation aliases, immutable Events, append-only recording/device/disposition/policy/drop/gap/annotation versions, store metadata, and a transactional FTS5 index. Startup SHALL validate JSON1, FTS5, foreign keys, and the expected schema before writes. An unknown newer schema, corruption, migration failure, or missing required SQLite feature SHALL fail closed without deleting or recreating data and SHALL NOT prevent the network listener from operating.

The Application Support directory SHALL be mode `0700`. Main database, WAL, SHM, rollback-journal/migration, and export-temporary artifacts SHALL be regular nonsymlink owner-only files with mode `0600` and SHALL be inspected while WAL is active and after close. SQLite SHALL use defensive/trusted-schema restrictions, memory-only temporary storage, and `secure_delete=ON` where supported. Documentation SHALL describe retention as logical deletion, not guaranteed erasure from WAL history, filesystem snapshots, or backups.

Read operations SHALL use short transactions with SQLite progress budgets. Generation-bound cancellation MAY call `sqlite3_interrupt` only for the matching active operation on that exact read connection and SHALL NOT interrupt a following operation or the writer.

#### Scenario: First launch creates schema version 1

- **WHEN** the expected Application Support database does not exist
- **THEN** Viewer creates it and every sidecar/temporary artifact under the owner-only nonsymlink policy in one migration transaction
- **AND** no SQLite dependency is added to Core, SDK, the root package manifest, or the podspec

#### Scenario: Existing schema is unsupported

- **WHEN** the database reports an unknown newer schema version or fails integrity/schema validation
- **THEN** persistence, query, and export become unavailable with one closed safe category
- **AND** Viewer neither recreates the database nor terminates active network sessions

#### Scenario: Query cancellation races completion

- **WHEN** cancellation arrives as a query completes and another read or write begins
- **THEN** only the generation-matching query may be interrupted
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

Operator documentation and bounded export-preflight disclosure metadata SHALL state that aliases are pseudonyms rather than redaction, Event/App content may identify secrets or people, output is unencrypted, export files are outside Viewer quota/retention/cleanup, and a destination provider may sync or back them up. The actual export selection/confirmation UI remains deferred.

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
