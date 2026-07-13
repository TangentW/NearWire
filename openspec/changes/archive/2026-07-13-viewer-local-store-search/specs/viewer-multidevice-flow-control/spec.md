## MODIFIED Requirements

### Requirement: Drop reporting and telemetry are bounded and content-free

Viewer SHALL maintain saturating per-session counters for local enqueue, dequeue, overflow drop, expiry, route drop, keep-latest coalescing, and remote drop summaries. It SHALL coalesce unsent local loss into at most one bounded wire drop summary on the protocol-defined Event lane without consuming business rate tokens. Remote summaries SHALL update telemetry only and SHALL NOT be reflected or treated as acknowledgement. Remote summaries MAY be persisted only as bounded drop samples and SHALL NOT become Event history.

Session snapshots SHALL include safe identity presentation, state, requested/effective rates, current queue counts/bytes/oldest wait, cumulative counters, approximate bounded one-second ingress/egress rates, and a closed terminal category. They SHALL NOT include Event content or metadata values, pairing code, endpoints, certificate/TLS material, wire bytes, or arbitrary transport errors. The full manager snapshot SHALL contain no more than 16 owned-session rows plus 64 recent rows and SHALL reach the main model through latest-only bounded delivery.

Every error, terminal category, description, debug description, reflection helper, interpolation, log, analytics value, clipboard value, and safe session/recent-row presentation SHALL derive only from a closed local code or explicitly bounded presentation model. These surfaces SHALL exclude Event type/content, Event metadata values, queue keys and contents, installation/correlation identifiers except the already bounded user-facing App/Bundle fields, session epochs, endpoints, certificate data, peer text, raw bytes, database paths, query text, SQL text/errors, and underlying errors.

The dedicated Viewer local-store boundary MAY persist validated logical Event content and metadata, bounded App/device correlation, requested/effective policy samples, drop samples, annotations, and safe lifecycle state exactly as specified by `viewer-local-store-search`. Those values SHALL remain absent from `UserDefaults`, logs, analytics, clipboard, safe status snapshots, and recent in-memory rows. Raw wire frames, queue keys, queue contents, pairing codes, endpoint/certificate/Keychain material, and exact session epochs SHALL remain absent from persistence and export. JSON export MAY contain validated Event content and safe analysis metadata only after applying the aliasing and omission rules of `viewer-local-store-search`. Effective policy MAY be persisted locally for analysis but SHALL remain absent from export and safe status. Packaging evidence SHALL reassess the Viewer privacy manifest against the new local Event store and bounded storage preferences and SHALL inspect the built privacy manifest.

Counter overflow SHALL saturate. Telemetry, journal, query, or persistence failure SHALL NOT terminate, block, or alter a device protocol session.

#### Scenario: Several local losses occur before mailbox capacity exists

- **WHEN** overflow and expiry occur while the bounded mailbox cannot admit the drop summary
- **THEN** Viewer retains one coalesced bounded drop summary
- **AND** later mailbox capacity sends the aggregate without blocking Event producers

#### Scenario: Remote reports dropped Events

- **WHEN** a valid remote drop summary arrives
- **THEN** remote-loss telemetry increases with saturation and may produce one bounded local drop sample
- **AND** Viewer emits no mirrored summary and infers no delivery acknowledgement

#### Scenario: UI telemetry is busy

- **WHEN** many session counters change in one main-run-loop interval
- **THEN** Viewer retains only the latest safe snapshot for UI delivery
- **AND** it creates no unbounded `MainActor` task backlog

#### Scenario: Event is committed for local journaling

- **WHEN** an uplink frame commits validation/sequence or a downlink frame commits secure-mailbox admission
- **THEN** the dedicated bounded store sink may receive the validated logical record and exact local disposition
- **AND** no log, `UserDefaults`, recent row, safe snapshot, or clipboard value receives its type, content, metadata, session epoch, or queue key

#### Scenario: Storage or query operation fails

- **WHEN** SQLite, indexing, cleanup, search, or export reports a failure
- **THEN** user-visible and diagnostic surfaces contain only a closed safe category
- **AND** no SQL, path, Event, identity, or underlying error value appears or changes the network session

## ADDED Requirements

### Requirement: The multi-device owner exposes bounded journal observations without transferring protocol ownership

The session manager SHALL expose immutable Viewer-internal journal observations for logical/durable recording-device lifecycle, committed uplink Events, append-only uplink terminal-disposition transitions, committed downlink mailbox admission, changed policy samples, and changed drop samples. Journal delivery SHALL be nonthrowing and constant-bounded per already-validated record on the connection core executor. Admission SHALL use the record's precomputed deterministic byte count plus fixed metadata reservation and copy-on-write value ownership; it SHALL perform no JSON encoding, content traversal, deep copy, or SQLite work. It SHALL NOT expose a network connection, decoder, mailbox mutation method, sequence counter, token bucket, queue, or terminal gate to storage.

#### Scenario: Store consumer is blocked or unavailable

- **WHEN** the journal sink cannot accept or persist an observation
- **THEN** the exact device session continues using its prior protocol, queue, token, timeout, and terminal state
- **AND** only bounded persistence-gap/status accounting changes
