# viewer-memory-session Specification

## Purpose
Define the Viewer's single bounded process-lifetime Session, explicit Clear boundary, and bounded JSON transfer without automatic persistence.
## Requirements
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

### Requirement: Memory Session Clear has one serialized boundary

Clear SHALL establish one serialized workspace boundary, remove all retained Events, Event details, dispositions, gaps, drops, and derived Performance content, and preserve listener state plus active Device connections. An Event admitted before the boundary SHALL be absent after success; an Event admitted after the boundary SHALL remain eligible for the successor snapshot. Stale pre-clear evaluation or projection completion SHALL NOT repopulate cleared content.

#### Scenario: Clear runs while an App remains connected

- **WHEN** the operator confirms Clear and an App is active
- **THEN** the retained memory Session becomes empty and Performance resets
- **AND** the App connection and Device lane remain available for successor Events

### Requirement: JSON transfer is explicit, bounded, and memory-backed

Viewer SHALL export one immutable snapshot of the currently retained memory Session as the supported
complete-Session JSON format after the existing unencrypted disclosure. Export SHALL include only
retained content and SHALL NOT claim unavailable database history. The selected destination SHALL
remain an explicit user artifact and SHALL NOT become Viewer persistence.

The export destination panel SHALL be presented from the originating Viewer window only after the
disclosure sheet has fully dismissed. Cancelling destination selection SHALL write no file, SHALL
retain the prepared immutable export until the operator explicitly closes or retries, and SHALL
restore a truthful disclosure state.

The sandboxed Viewer SHALL carry the user-selected file read/write entitlement for both import and
export. Selection through the native panel SHALL grant access only to the operator-selected file
location and SHALL NOT grant general filesystem access.

Import SHALL be available only when no App is active, disconnecting, or awaiting approval. It SHALL
validate the supported complete-Session schema, at most 16 Devices, at most 256 MiB of accounted
Event data, the byte-derived finite carrier capacity, and a 256-MiB input file before atomically
replacing the inactive memory Session. It SHALL NOT reject an otherwise byte-valid Session merely
because it contains more than 512 Events. Unsupported, invalid, cancelled, or over-limit input SHALL
leave the existing Session unchanged. Imported Devices SHALL remain offline pseudonyms and SHALL NOT
restore TLS identity, installation identity, connection capability, queue state, or delivery claims.

The import source panel SHALL be presented from the originating Viewer window only after its
replacement disclosure has fully dismissed. Cancelling source selection SHALL return the workspace
from selection to idle and SHALL NOT replace the current Session.

#### Scenario: Retained Session is exported

- **WHEN** the operator accepts the disclosure and the disclosure sheet finishes dismissing
- **THEN** Viewer presents a save panel attached to the originating Viewer window
- **AND** choosing a destination atomically writes the retained Events and Device metadata as
  unencrypted JSON
- **AND** it does not create a database or remember the destination

#### Scenario: Export destination selection is cancelled

- **WHEN** the operator cancels the save panel
- **THEN** no destination is written or replaced
- **AND** Viewer restores the prepared disclosure so the operator can retry or close it

#### Scenario: Sandboxed Viewer chooses a transfer file

- **WHEN** the operator chooses an import source or export destination through the native panel
- **THEN** the sandboxed Viewer can read or write that selected location
- **AND** no broader filesystem entitlement is required

#### Scenario: Valid bounded Session is imported

- **WHEN** no App is active or pending, the replacement disclosure finishes dismissing, and the
  operator chooses a supported file within every memory bound
- **THEN** Viewer atomically replaces the current Session and presents imported Devices as offline
- **AND** filters, details, and Performance use the replacement memory snapshot

#### Scenario: Import source selection is cancelled

- **WHEN** the operator cancels the open panel
- **THEN** Viewer leaves the current Session unchanged
- **AND** the workspace returns from import selection to idle

#### Scenario: Import exceeds a memory bound

- **WHEN** a file exceeds Device, 256-MiB file, 256-MiB accounted-byte, or byte-derived carrier bounds
- **THEN** import fails with fixed guidance and changes no current-Session content
