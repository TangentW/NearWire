# NearWire Viewer Process Workspace

## Product boundary

The Viewer uses SQLite only as the bounded working authority for the one Session owned by the
current process. It does not expose persisted Sources, saved recordings, quota or retention
controls, and it does not reopen the working Store on a later launch.

The existing schema and query machinery remain useful for deterministic Event ordering, filters,
details, gaps, Performance aggregation, transactional Clear, and complete-Session JSON
import/export. They are internal implementation details rather than a user-facing history product.

## Lifecycle and ownership

Each launch creates a unique directory named `workspace-<pid>-<nonce>` below
`NearWire-Viewer-Workspaces` in the user's temporary directory. The directory and Store files use
owner-only permissions. A no-follow marker contains the exact workspace leaf name; shutdown closes
the writer and readers before exact marked-directory removal. Cleanup refuses an unowned,
unexpected, symbolic-link, or mismatched path.

Application termination owns one idempotent cleanup task and waits for it for at most one second.
That task retains cleanup ownership while the process is alive, closes SQLite before unlinking,
and retries an exact marked-directory removal up to four times with bounded backoff. Termination is
not held open indefinitely: a permanent validation/removal failure or process exit can leave the
marked temporary directory behind, but a later Viewer never catalogs or reopens it.

The working SQLite database is not application-level encrypted at rest. Owner-only permissions
reduce access by other local users, but anyone who can act as the signed-in user may read Event
content. Terminal unlink and SQLite `secure_delete` are best-effort lifecycle cleanup, not a
guarantee that SSD media, filesystem snapshots, caches, or backups contain no recoverable copy.

An interrupted process can leave a temporary directory for operating-system cleanup, but NearWire
does not enumerate or reopen it as a Source. No background daemon extends the Session lifetime.

## SQLite boundary

One serialized writer owns schema changes and Event mutations. Dedicated bounded readers serve
queries and export. SQLite uses WAL mode, foreign keys, defensive settings, trusted schema off,
bounded busy handling, progress interruption, and owner-only files. Event identity for admission is
the current recording, Device session, direction, and wire sequence tuple; a peer Event UUID is not
assumed globally unique.

Schema version 3 adds retained Event, gap, and annotation counters with transactional triggers. A
valid schema-version-2 working Store encountered during same-process recovery initializes those
counters from durable rows in one cancellable migration before normal connections open.

The Store retains the current Session's Event metadata, canonical JSON content, dispositions,
diagnostic gaps, annotations, and Device mappings. In-memory presentation remains independently
bounded and may label a row `Not recorded` when the Store is unavailable.

Live transport supports sixteen concurrent Devices. The working Store and complete JSON transfer
share a separate 4,096-row bound for reconnect history. Reaching that durable bound keeps later
connections live but records bounded storage-unavailable diagnostics instead of producing an
export that the importer cannot consume.

The working Store and complete transfer also share retained-count limits of 2,000,000 Events,
500,000 gaps, and 100,000 annotations. Complete transfer files are limited to 4 GiB. A Store append
that would exceed a retained-count limit is rejected and released through the bounded `Not
recorded`/diagnostic path, so ingress can keep draining and Clear remains available. Transactional
SQLite counters make each retained-limit check constant-time and are reconciled when the schema is
opened. A complete export whose frozen snapshot or streamed JSON would exceed a transfer limit
stops before writing beyond 4 GiB and fails before replacing the selected destination, so NearWire
never emits a complete file its importer is defined to reject.

## Clear transaction

Clear is one writer transaction. It removes Events and every Event-derived row, reconciles logical
quota accounting, and preserves the current recording and Device-session rows. The live projection
is cleared only after the transaction succeeds. Event commits, Clear, and import share one
serialization gate. Clear remains available while Apps are connected: already admitted live
decisions are drained into the serialized Store prefix before the delete boundary, and later Events
remain in the current Session.

## Complete-Session import

Import opens a no-follow regular file read-only, checks a fixed maximum byte count, copies it into
an owner-only immutable workspace snapshot with bounded descriptor reads, verifies that the source
identity did not change, and memory-maps only that owned snapshot. The parser requires the exact supported
root schema and disclosure, bounds JSON nesting and array counts, and validates every Device,
Event, gap, annotation, identifier, and text field. Cancellation is polled while copying, scanning
the root structure, validating records, staging the transaction, and executing the bulk SQLite
replacement through a progress handler. Peer Event UUIDs may repeat; the Device, direction, and
wire-sequence journal key remains the uniqueness boundary.

Replacement is atomic. Cancellation is checked throughout parsing and immediately before commit.
Failure or cancellation rolls back the transaction. Viewer acquires the admission/session lease
before showing the file picker, so import is allowed only while there are no active, negotiating,
disconnecting, nondurable, or pending Apps. Imported Devices receive new local
identities and closed/offline sessions, so file content cannot create a live routing authority.

## JSON export

Export freezes a complete current-Session snapshot and streams a schema-version-1 document through
bounded reads and chunks. It writes an owner-only temporary leaf and commits with a same-directory
rename after synchronization. Cancellation before the commit seal preserves the prior destination.
The producer validates the same Device/Event/gap/annotation counts as the importer, enforces the
shared 4 GiB limit incrementally before each streamed write, and checks the finished temporary file
again before committing it.

Exports are unencrypted and no longer belong to the process workspace. Device and connection names
are pseudonyms, not redaction. Session metadata and notes, annotations and diagnostic gaps, Event
metadata and content, and peer-provided App display name, application identifier, and application
version fields are included verbatim. App hints remain unauthenticated. Those fields can contain
secrets, personal information, or identifying data, and the selected destination provider may
synchronize or back up the file. The operator must review the disclosure before sharing it.

## Failure behavior

Networking remains available if the working Store cannot start. Rows accepted only by the bounded
live projection remain explicitly `Not recorded` and are excluded from complete-Session export.
Recovery affects future writes only; it never claims that evicted memory-only content became
durable. User-visible errors use fixed categories and do not interpolate paths, SQL, raw content,
peer identifiers, or operating-system diagnostics.
