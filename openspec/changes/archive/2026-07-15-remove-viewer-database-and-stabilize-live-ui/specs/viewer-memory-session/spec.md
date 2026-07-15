## ADDED Requirements

### Requirement: Viewer retains one bounded memory-only current Session

The production Viewer SHALL use one process-lifetime in-memory current Session as the only authority for received Event presentation, detail, filtering, diagnostics, and Performance input. It SHALL retain at most 512 Events, 32 MiB of accounted Event data, and 16 Device-session metadata lanes, with the existing bounded ingress. It SHALL NOT create, open, query, recover, clean, or close a SQLite database or another local persistence engine for Sources or Sessions. A later process SHALL start empty unless the operator explicitly imports a supported JSON file.

Oldest-Event eviction SHALL preserve newer Event progress and expose one bounded in-memory-window gap. Shutdown, identity reset, listener failure cleanup, or runtime replacement SHALL clear all received Event content and derived Performance values.

#### Scenario: Viewer receives Events during one launch

- **WHEN** Apps send Events within the memory bounds
- **THEN** Timeline, Inspector, filters, and Performance consume the same in-memory Session snapshot
- **AND** no Session database file or database lifecycle work is created

#### Scenario: The memory window reaches its bound

- **WHEN** another accepted Event would exceed retained count or accounted bytes
- **THEN** the oldest retained Events are evicted within the fixed bound and a bounded gap is shown
- **AND** the connection and newer Event admission continue

#### Scenario: Viewer launches again

- **WHEN** a new Viewer process starts after a prior process ended or crashed
- **THEN** it starts with an empty current Session
- **AND** no prior Source or Session is recovered automatically

### Requirement: Memory Session Clear has one serialized boundary

Clear SHALL establish one serialized workspace boundary, remove all retained Events, Event details, dispositions, gaps, drops, and derived Performance content, and preserve listener state plus active Device connections. An Event admitted before the boundary SHALL be absent after success; an Event admitted after the boundary SHALL remain eligible for the successor snapshot. Stale pre-clear evaluation or projection completion SHALL NOT repopulate cleared content.

#### Scenario: Clear runs while an App remains connected

- **WHEN** the operator confirms Clear and an App is active
- **THEN** the retained memory Session becomes empty and Performance resets
- **AND** the App connection and Device lane remain available for successor Events

### Requirement: JSON transfer is explicit, bounded, and memory-backed

Viewer SHALL export one immutable snapshot of the currently retained memory Session as the supported complete-Session JSON format after the existing unencrypted disclosure. Export SHALL include only retained content and SHALL NOT claim unavailable database history. The selected destination SHALL remain an explicit user artifact and SHALL NOT become Viewer persistence.

Import SHALL be available only when no App is active, disconnecting, or awaiting approval. It SHALL validate the supported complete-Session schema, at most 16 Devices, at most 512 Events, at most 32 MiB of accounted Event data, and a bounded input file before atomically replacing the inactive memory Session. Unsupported, invalid, cancelled, or over-limit input SHALL leave the existing Session unchanged. Imported Devices SHALL remain offline pseudonyms and SHALL NOT restore TLS identity, installation identity, connection capability, queue state, or delivery claims.

#### Scenario: Retained Session is exported

- **WHEN** the operator accepts the disclosure and chooses a destination
- **THEN** Viewer atomically writes the retained Events and Device metadata as unencrypted JSON
- **AND** it does not create a database or remember the destination

#### Scenario: Valid bounded Session is imported

- **WHEN** no App is active or pending and a supported file is within every memory bound
- **THEN** Viewer atomically replaces the current Session and presents imported Devices as offline
- **AND** filters, details, and Performance use the replacement memory snapshot

#### Scenario: Import exceeds a memory bound

- **WHEN** a file exceeds Device, Event, file, or accounted-byte bounds
- **THEN** import fails with fixed guidance and changes no current-Session content
