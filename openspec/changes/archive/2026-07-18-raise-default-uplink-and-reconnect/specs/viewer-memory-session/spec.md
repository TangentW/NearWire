## MODIFIED Requirements

### Requirement: Viewer retains one bounded memory-only current Session

The production Viewer SHALL use one process-lifetime in-memory current Session as the only authority
for received Event presentation, detail, filtering, diagnostics, and Performance input. It SHALL
retain Events within 256 MiB of accounted Event data and 16 Device-session metadata lanes. Its
bounded callback ingress SHALL admit at most 2,048 Events and 64 MiB of accounted Event data. Both
ingress bounds SHALL remain authoritative. It SHALL NOT apply an independent fixed Event-count
retention policy. Internal slot capacity MAY be derived from the byte budget and the minimum fixed
per-Event accounting overhead solely to represent every byte-valid Session with finite storage. It
SHALL NOT create, open, query, recover, clean, or close a SQLite database or another local
persistence engine for Sources or Sessions. A later process SHALL start empty unless the operator
explicitly imports a supported JSON file.

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

#### Scenario: Viewer receives a bounded high-rate burst

- **WHEN** at most 2,048 small observations remain within the 64-MiB callback-ingress budget
- **THEN** callback admission can retain them for the serial projection drain
- **AND** the retained Session's existing 256-MiB byte budget remains unchanged

#### Scenario: Callback ingress reaches either bound

- **WHEN** another observation would exceed 2,048 entries or 64 MiB
- **THEN** ingress rejects it through the existing bounded loss path
- **AND** no retained-Session, connection, sequence, queue, or rate bound is expanded implicitly

#### Scenario: Viewer launches again

- **WHEN** a new Viewer process starts after a prior process ended or crashed
- **THEN** it starts with an empty current Session
- **AND** no prior Source or Session is recovered automatically
