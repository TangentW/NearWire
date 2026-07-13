# Viewer Local Store

NearWire Viewer records admitted Events and recording lifecycle observations in a local SQLite database. The store is a Viewer-only implementation. It is not linked by NearWireCore or the iOS SDK.

## Ownership and schema

The Viewer links the system `libsqlite3` and owns exactly three serialized connections:

- the writer owns schema migration, Event admission, metadata changes, retention, and reclaim;
- the interactive reader owns bounded search, detail, and keyset pagination;
- the export reader owns bounded JSON export pages.

The version 1 schema keeps immutable recording, device-session, installation-alias, and Event base rows. Changes are appended to recording, device, disposition, policy, drop, gap, and annotation version tables. SQLite AUTOINCREMENT row identifiers are never reused. Event identity for durable admission is the recording, device session, direction, and wire sequence tuple. A peer-provided Event UUID is content and is not assumed to be unique. Event causality IDs, TTL, schema version, source monotonic time, and Viewer admission time are retained as immutable Event metadata.

The store never persists TLS material, raw wire frames, transport security state, or session epochs. Installation identifiers remain local and exports replace them with stable `device-N` pseudonyms. Reconnects use `connection-N` aliases within a recording.

## Files and protection

The Application Support directory is owner-only (`0700`). The database, active WAL and shared-memory sidecars, rollback journal, migration files, and export temporary files are regular nonsymlink files with owner-only permissions (`0600`). Paths that resolve to symbolic links or unexpected file types are rejected.

SQLite uses WAL, full synchronization, foreign keys, defensive mode, an untrusted schema, memory-only temporary storage, and `secure_delete`. Startup probes the schema shape and the required SQLite features. Every mutation must preserve a 64 MiB volume floor after adding its checked planned work; overflow or unavailable capacity fails before the transaction begins. An unknown or incomplete schema fails closed and is never deleted or recreated automatically; after external repair, the operator can use Retry Storage. Secure delete reduces recoverable remnants in SQLite-managed pages; it is not a secure-erasure guarantee for SSD media, snapshots, caches, synchronized folders, or backups.

The local SQLite database is not encrypted by NearWire at the application layer. Owner-only permissions limit access through the normal filesystem boundary, and system protections such as FileVault may protect the volume when configured, but NearWire does not detect, require, or guarantee FileVault or equivalent at-rest protection.

## Recording and gaps

Networking remains available if storage cannot start. A connection that begins while storage is unavailable is nondurable. A later retry creates the original logical recording, marks only devices that are still connected as partial-history devices, and records a storage gap. Devices that ended while storage was unavailable are not invented later.

On startup, orphan recovery closes children before their recording parent in bounded transactions. It processes one recording group at a time, closes no more than 16 children in a turn, and performs at most eight immediate turns. If recovery cannot finish, the Viewer continues networking without claiming durable history.

Journal callbacks are scoped to the logical runtime that created them. A new window may begin networking while an older window's bounded storage cleanup is still finishing, but the new runtime remains nondurable until a fresh coordinator reopens its own recording. Late callbacks or repeated cleanup from the older runtime cannot write into or close the replacement runtime.

Within one coordinator generation, the connection identifier is the stable logical device identity. Repeating session start or recovery for an already durable live connection reuses its existing device row. A global retry materializes only still-live nondurable connections; it never creates a second device session for an uninterrupted durable connection.

The protocol executor transfers precomputed observations through bounded queues that share one end-to-end ownership budget. Event ownership defaults to 4,096 records and 32 MiB and cannot be configured above 8,192 records or 64 MiB across preparation and writer admission combined. Structural observations share one 36-record lane; ordinary disposition, policy, drop, and gap observations can own at most 18 slots so the remaining 18 stay available to runtime/device lifecycle, recovery, and shutdown. Normal writes use at most 256 observations or 4 MiB; one Event up to 20 MiB may use the oversize path. Queue overflow, preparation failure, retry, and disposition loss are represented as coalesced gaps when durable storage is available. A terminal transition whose initial Event is absent uses a sequence identity that also includes its terminal disposition: the same outcome is idempotent even if observed later, while a different outcome is a store-only conflict. If a lifecycle operation cannot enter its reserved ownership, the runtime reports storage unavailable and counts later observations until an explicit retry replays the stable runtime context and still-live devices.

## Quota, retention, and reclaim

The default logical quota is 3 GiB and default `historyRetention` is seven days. Viewer settings accept 64 MiB through 1 TiB and 1 through 3,650 days. Event quota reservation is twice the deterministic canonical Event size plus 1 KiB; structural records use checked fixed or text-derived reservations. The UI reports logical quota separately from the database/WAL/shared-memory allocated footprint.

Maintenance is triggered by startup, settings changes, session close, each 8 MiB of committed Event data, one replaceable 15-minute wake while the runtime is active, or an explicit operator action. A trigger performs at most eight immediate turns. Retention-expired recordings are selected before capacity-only candidates. Selection skips active, pinned, and read-leased recordings and tombstones no more than 32 recordings in one transaction. When capacity cleanup is required, selection targets 85 percent of the configured quota. Writes can continue after eligible data is exhausted between 85 and 100 percent; exceeding 100 percent pauses durable writes until cleanup or an explicit retry succeeds.

Logical tombstones hide a complete recording immediately. Physical reclaim budgets the Event row, its FTS trigger work, and at most two schema-enforced disposition rows together: a normal turn performs at most 1,024 counted row operations or 4 MiB of Event-plus-disposition quota. One oversized Event and its dependent work may use a bounded 41 MiB turn. Other recording-owned tables are reclaimed in separately bounded phases. An impossible head record is isolated so later tombstones can continue. Each turn determines its next bounded action before checking disk capacity and reserves only that action's checked plan; read-only/no-work inspection does not inherit the unrelated 41 MiB oversize plan. The database uses incremental auto-vacuum; passive WAL checkpoint and at most 64 free pages of incremental reclamation are separate opportunistic turns. They require at least a 64 MiB filesystem safety margin and never authorize extra logical deletion. On APFS, a bounded incremental-vacuum turn can reduce SQLite `freelist_count` and `page_count` without immediately reducing the file's reported allocated bytes; later checkpoints, filesystem allocation policy, snapshots, and backups control when those bytes are physically returned.

History retention is independent of an Event's transport TTL. TTL controls transport eligibility; `historyRetention` controls already-recorded history.

## Search and snapshots

Query models allow at most 32 predicates and 16 selected devices. Different filter dimensions combine with AND; selected values inside one dimension combine with OR. Search text is limited to 512 UTF-8 bytes and 32 literal terms, normalizes a search copy to NFC, quotes FTS terms, and binds every value as a SQLite parameter. Exact Event types use the canonical 128-byte dot-separated ASCII grammar; prefixes use the same segment grammar while permitting a partial final segment or one trailing dot. Event-type prefix uses binary `substr`; JSON containment uses `instr`; JSON scalar queries accept only the closed root/dot/index path grammar with ASCII array indexes. NUL and disallowed controls are rejected.

One bounded latest-only change snapshot retains at most 32 internal recording row IDs, the
committed internal Event upper row ID, and safe store status so a trusted in-process consumer can
refresh incrementally. Its descriptions, interpolation, and reflection are content-free: generic
diagnostics and presentation expose neither those internal row identities nor Event types, content,
peer identities, query values, SQL, or result arrays.

Event envelopes, contexts, records, single/batch payloads, frames, admitted messages, received/downlink journal carriers, the frame decoder, and structural policy, drop, and gap observations expose only fixed redacted descriptions and bounded content-free mirrors. Generic interpolation, debugging, and direct reflection cannot traverse Event content, raw frame bytes, endpoints, epochs, identifiers, causality, or arbitrary structural metadata.

Pages contain 1 through 200 rows and default to 100. They use the `(viewerMonotonicNs, rowID)` keyset and never use `OFFSET`. A query lease freezes upper row identifiers for Events and every relevant append-only version table. At most eight query leases exist; they expire after 60 seconds idle or ten minutes absolute. Each page has a 250 ms and virtual-machine work budget. Cleanup and manual delete skip recordings protected by a live lease.

## JSON export

The exporter accepts one complete recording or one validated frozen query and permits one lease for at most 60 minutes. It freezes base recording, device-session, and installation-alias rows plus all relevant append-only row identifiers. The dedicated reader uses short transactions, emits one Event per database read, applies one-second work budgets, and writes output chunks no larger than 64 KiB. Cancellation checks only the matching export generation throughout query, encoding, chunked writing, file synchronization, close, and the lock-coupled commit seal. Cancellation that wins before the seal preserves the prior destination; once the seal succeeds, cancellation no longer claims the commit.

The schema-version-1 document contains session, device, Event, gap, and annotation data. Events include safe causality and local disposition metadata but omit session epochs, endpoints, transport security state, and pairing material. Export opens the parent directory once without following links, creates the owner-only temporary leaf with `openat`, retains its original descriptor through synchronization and commit, verifies descriptor/leaf/parent identity, and replaces the destination with `renameat` relative to that same parent. Successful rename is the single irreversible commit point: every reported pre-commit error preserves the prior destination, while post-rename observer or best-effort parent-directory synchronization failure cannot be misreported as an uncommitted export. No swap, rollback-copy, unlink, or second-sync phase exists.

The filesystem-capacity check uses the standard macOS volume available-capacity resource value. The packaged privacy manifest remains responsible for the existing UserDefaults and device-identity declarations; the local capacity query does not transmit data or add a tracking purpose.

JSON exports are unencrypted and are outside Viewer quota and retention. `device-N` and `connection-N` are pseudonyms, not redaction. Event types, content, and metadata can still identify people, devices, secrets, or applications. The selected destination or its provider may synchronize or back up the file. Operators must review the preflight disclosure before sharing an export.

## Event Explorer integration

The local store remains the authority for durable history, query snapshots, recording revisions,
leases, cleanup, and export. The native Event Explorer consumes those bounded services without
exposing SQLite, SQL, paths, or coordinator ownership to presentation code. Live-versus-recorded
semantics, history UI, filters, renderers, recording operations, export workflow, and control
composition are documented in [Viewer-Event-Explorer.md](Viewer-Event-Explorer.md). Performance
charts remain a separate capability.
