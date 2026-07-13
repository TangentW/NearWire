## MODIFIED Requirements

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

## ADDED Requirements

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
