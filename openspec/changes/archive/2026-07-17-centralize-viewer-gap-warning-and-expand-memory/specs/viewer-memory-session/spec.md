## MODIFIED Requirements

### Requirement: Viewer retains one bounded memory-only current Session

The production Viewer SHALL use one process-lifetime in-memory current Session as the only authority
for received Event presentation, detail, filtering, diagnostics, and Performance input. It SHALL
retain Events within 256 MiB of accounted Event data and 16 Device-session metadata lanes. Its
bounded callback ingress SHALL admit at most 256 Events and 64 MiB of accounted Event data. It SHALL
NOT apply an independent fixed Event-count retention policy. Internal slot capacity MAY be derived
from the byte budget and the minimum fixed per-Event accounting overhead solely to represent every
byte-valid Session with finite storage. It SHALL NOT create, open, query, recover, clean, or close a
SQLite database or another local persistence engine for Sources or Sessions. A later process SHALL
start empty unless the operator explicitly imports a supported JSON file.

The maintained Viewer production and test targets SHALL contain no SQLite linkage or import,
Objective-C SQLite bridge, SQL statement, schema/table definition, database connection or
transaction wrapper, Store catalog/gateway/lease/maintenance/recovery implementation, storage
preference for Session data, or database-only test. Former database files SHALL be deleted rather
than retained as unreachable compatibility code. Pure JSON Session transfer and closed filter
validation MAY remain only in memory-focused files without database APIs.

Oldest-Event eviction SHALL occur only when required by the 256-MiB accounted-byte budget, preserve
newer Event progress, and expose one bounded Session-wide in-memory-window gap above Timeline
content. Ingress overflow and diagnostic loss SHALL use the same Session-wide diagnostic surface.
They SHALL NOT mark every retained or successor Event as individually gapped. Shutdown, identity
reset, listener failure cleanup, or runtime replacement SHALL clear all received Event content and
derived Performance values.

#### Scenario: Maintained Viewer sources are scanned

- **WHEN** production, test, and Xcode project paths are scanned after cleanup
- **THEN** they contain no SQLite import/link, SQL schema or table statement, database source group,
  or database-only test suite
- **AND** archived OpenSpec history is excluded from the maintained-code scan

#### Scenario: Viewer receives Events during one launch

- **WHEN** Apps send Events within the memory bounds
- **THEN** Timeline, Inspector, filters, Renderer, and Performance consume the same in-memory Session
  snapshot
- **AND** no database compatibility gateway, catalog request, or lifecycle work is constructed

#### Scenario: More than 512 small Events fit the memory window

- **WHEN** more than 512 retained Events remain within the 256-MiB accounted-byte budget
- **THEN** Viewer retains them without count-triggered eviction
- **AND** Timeline can present every matching retained Event

#### Scenario: The memory window reaches its byte bound

- **WHEN** another accepted Event would exceed 256 MiB of accounted Event data
- **THEN** the oldest retained Events are evicted until the new Event fits and one Session-wide gap
  warning is shown above Timeline content
- **AND** the connection and newer Event admission continue without adding a Gap badge to every row

#### Scenario: Viewer launches again

- **WHEN** a new Viewer process starts after a prior process ended or crashed
- **THEN** it starts with an empty current Session
- **AND** no prior Source or Session is recovered automatically

### Requirement: JSON transfer is explicit, bounded, and memory-backed

Viewer SHALL export one immutable snapshot of the currently retained memory Session as the supported
complete-Session JSON format after the existing unencrypted disclosure. Export SHALL include only
retained content and SHALL NOT claim unavailable database history. The selected destination SHALL
remain an explicit user artifact and SHALL NOT become Viewer persistence.

Import SHALL be available only when no App is active, disconnecting, or awaiting approval. It SHALL
validate the supported complete-Session schema, at most 16 Devices, at most 256 MiB of accounted
Event data, the byte-derived finite carrier capacity, and a 256-MiB input file before atomically
replacing the inactive memory Session. It SHALL NOT reject an otherwise byte-valid Session merely
because it contains more than 512 Events. Unsupported, invalid, cancelled, or over-limit input SHALL
leave the existing Session unchanged. Imported Devices SHALL remain offline pseudonyms and SHALL NOT
restore TLS identity, installation identity, connection capability, queue state, or delivery claims.

#### Scenario: Retained Session is exported

- **WHEN** the operator accepts the disclosure and chooses a destination
- **THEN** Viewer atomically writes the retained Events and Device metadata as unencrypted JSON
- **AND** it does not create a database or remember the destination

#### Scenario: Valid bounded Session is imported

- **WHEN** no App is active or pending and a supported file is within every memory bound
- **THEN** Viewer atomically replaces the current Session and presents imported Devices as offline
- **AND** filters, details, and Performance use the replacement memory snapshot

#### Scenario: Import exceeds a memory bound

- **WHEN** a file exceeds Device, 256-MiB file, 256-MiB accounted-byte, or byte-derived carrier bounds
- **THEN** import fails with fixed guidance and changes no current-Session content
