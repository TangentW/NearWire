## MODIFIED Requirements

### Requirement: Viewer owns one local SQLite store with explicit schema and failure boundaries

Viewer SHALL own one SQLite working Store for the current process-scoped Session under a unique exact NearWire-owned directory. SQLite SHALL remain an internal bounded query, filter, detail, performance, Clear, import, and export engine; its internal recording row SHALL NOT become a user-visible Source. The working Store SHALL use the existing explicit schema, three serialized connections, WAL, foreign keys, defensive/trusted-schema settings, permissions, cancellation, and safe failure boundaries. Viewer SHALL NOT reopen the directory as historical Viewer state in a later process.

Terminal application cleanup SHALL close every connection before removing only the exact non-symlink working directory and its NearWire ownership marker. Termination SHALL wait at most one second; the retained cleanup owner SHALL use bounded removal retries while the process remains alive and SHALL NOT block application exit indefinitely. A timeout, permanent removal failure, or crash MAY leave a temporary directory for operating-system cleanup; a later Viewer process SHALL NOT adopt its Session content. Store unavailability SHALL preserve bounded live presentation and fixed recovery guidance without creating a historical fallback.

Schema version 3 SHALL add transactionally maintained retained Event, gap, and annotation counters. A valid schema-version-2 working Store encountered during same-process recovery SHALL migrate those counters and their triggers atomically from durable row counts before normal connections open. Migration failure or cancellation SHALL leave the schema-version-2 Store unchanged.

#### Scenario: Viewer launches twice

- **WHEN** a later Viewer process starts after an earlier working Session ended or crashed
- **THEN** it creates a distinct empty working Session and does not catalog or reopen the earlier recording
- **AND** no prior Event appears unless the operator explicitly imports a supported export

#### Scenario: Query cancellation races completion

- **WHEN** one query token is cancelled as its SQLite operation completes
- **THEN** only that exact operation observes cancellation
- **AND** queued or successor working-Session operations are not poisoned

#### Scenario: Existing schema-version-2 Store recovers

- **WHEN** same-process recovery opens a valid schema-version-2 Store that predates retained counters
- **THEN** Viewer installs schema-version-3 counters and triggers in one migration transaction
- **AND** every initialized counter equals its authoritative durable row count

### Requirement: Viewer automatically records one working-Session lifecycle

Every accepted Viewer runtime SHALL materialize exactly one internal current recording, support up to 16 concurrently connected Devices, and retain at most 4,096 durable reconnect Device-session rows for the process-scoped working Session. The Store, complete exporter, and importer SHALL share retained-count bounds of 4,096 Devices, 2,000,000 Events, 500,000 gaps, and 100,000 annotations. Complete transfer files SHALL be limited to 4 GiB. Event, gap, and annotation retained-count checks SHALL use transactionally maintained constant-time counters. If a retained bound is exhausted, the offending ingress entry or Event batch SHALL be rejected and released through the bounded unavailable-storage path; ingress flush and a later Clear SHALL remain live. Reconnects, connected Devices, Events, dispositions, gaps, drops, and Performance inputs SHALL remain bound to that Session. Viewer SHALL expose no recording history, pin, retention, rename, note, annotation, or historical Source selection UI.

The Store MAY recover during the same process and replay bounded runtime/device lifecycle metadata needed to resume current capture, but a later process SHALL start an empty Session. The runtime logical ID remains the only current source identity used by Explorer and Performance.

Coordinator gap sequence allocation SHALL resume from the durable maximum coordinator sequence for the current recording. Clear MAY reset the sequence to one only after all current gaps are deleted. Import SHALL advance the successor beyond every imported coordinator gap so a later runtime diagnostic cannot collide with imported or pre-recovery rows.

#### Scenario: Several Devices share one Viewer runtime

- **WHEN** several Apps connect, disconnect, and reconnect during the process
- **THEN** their Device rows and Events remain queryable under the one current working Session
- **AND** Devices never become separate Sources

#### Scenario: Viewer reopens

- **WHEN** the application starts in a new process
- **THEN** it exposes one empty current Session
- **AND** the prior process Session is available only through an explicit previously exported file

## RENAMED Requirements

- FROM: `### Requirement: Viewer automatically records runtime and device-session lifecycle`
- TO: `### Requirement: Viewer automatically records one working-Session lifecycle`

## ADDED Requirements

### Requirement: Current Session Clear is atomic and generation safe

The Store SHALL expose one serialized destructive Clear operation for the current working Session. After explicit operator confirmation, it SHALL establish a write boundary, reject or cancel predecessor query/export/import leases, and delete current Event rows, Event disposition and full-text rows, gaps, drops, annotations, and other Event-derived Performance inputs in one transaction. It SHALL preserve the current internal recording, Device-session lifecycle rows, active connection ownership, listener state, rate policy, and Viewer identity.

Clear success SHALL advance Store and presentation generations. The live window SHALL discard every pre-boundary Event and diagnostic value before successor presentation is admitted. Pre-clear page, detail, renderer, Performance, or export completion SHALL update no UI. Events admitted after the boundary SHALL remain. Failure or cancellation SHALL leave all Session data unchanged.

#### Scenario: Event commit races Clear

- **WHEN** one Event write is admitted before the serialized Clear boundary and another is admitted after it
- **THEN** the earlier Event is absent and the later Event remains
- **AND** neither a stale durable page nor a stale live row can restore the earlier Event

#### Scenario: Clear transaction fails

- **WHEN** any dependent delete or generation update fails
- **THEN** the Store rolls back the complete Clear
- **AND** the existing timeline and Performance projection remain authoritative

### Requirement: Session JSON transfer is bounded, explicit, and atomic

Complete current-Session export SHALL retain the existing unencrypted JSON disclosure, finite export lease, frozen snapshot, bounded streaming, cancellation, and atomic destination replacement. The file SHALL identify whether it is a complete Session. Filtered exports SHALL NOT be accepted as Session imports.

Import SHALL require a separate destructive replacement disclosure and SHALL be admitted only when there is no active, negotiating, or disconnecting Device and no pending App approval. It SHALL accept only a regular non-symlink complete NearWire JSON export at the supported schema version. A mapped structural scanner SHALL decode one bounded value at a time, validate file and per-record limits, strict cross-references, canonical Event fields, JSON content, and Session completeness without materializing the complete document graph.

The import scanner SHALL observe cancellation during snapshot copying, root structural scanning, per-record validation, and transactional staging at bounded intervals. The SQLite progress handler SHALL interrupt a cancelled bulk replacement and roll back the transaction. Peer Event UUIDs SHALL remain non-unique content; only the canonical Device/direction/wire-sequence journal key SHALL be unique.

Imported aliases SHALL remain offline pseudonyms. Complete export disclosure SHALL state that Session metadata and notes, annotations and diagnostic gaps, Event metadata and content, and peer-provided App display name, application identifier, and application version are included verbatim; App hints remain unauthenticated. Viewer SHALL generate new local runtime/device identities and SHALL NOT import installation identifiers, TLS material, pairing state, endpoints, raw connection IDs, queue state, control capabilities, delivery acknowledgements, or trust. Import SHALL stage all rows and atomically replace current Session Event-derived data. Failure, cancellation, unsupported schema, filtered input, ambiguity, invalid content, or configured Store capacity exhaustion SHALL change nothing and expose a fixed safe category with applicable operator guidance. Import and export destinations SHALL never persist.

The complete exporter SHALL validate the same retained-count and file-size limits as the importer. It SHALL enforce the file limit incrementally before streamed bytes exceed the bound and verify the completed temporary file again. If the frozen snapshot or streamed temporary file exceeds a shared transfer limit, export SHALL fail before replacing the operator's destination and SHALL provide fixed guidance to reduce or Clear the Session rather than filter-query guidance.

#### Scenario: Complete Session round trip

- **WHEN** the operator exports the current Session, clears it, and imports that complete file while no Device is active
- **THEN** bounded Events, device pseudonyms, dispositions, gaps, and supported metadata rematerialize under new local identities
- **AND** no transport identity, control capability, or delivery claim is restored

#### Scenario: Import is attempted while a Device is active

- **WHEN** any Device connection or pending approval belongs to the current runtime
- **THEN** import is rejected before file selection or Store mutation with fixed guidance
- **AND** capture and the current Session remain unchanged

#### Scenario: Import validation fails

- **WHEN** the file is a filtered export, unsupported schema, symbolic link, oversized record, malformed JSON, or has an unresolved Device reference
- **THEN** no current row is changed
- **AND** no untrusted imported value appears in diagnostics or logs
