# NearWire Viewer Event Explorer and Control Guide

## Scope

The Event Explorer is the native macOS workspace for inspecting Events received from Apps,
reviewing recorded history, and requesting Viewer-to-App control Events. It composes with the
existing pairing, approval, device telemetry, rate, storage, and identity controls. It does not
replace the session manager, transport, or local store.

The workspace has three columns and one bottom composer:

```text
Sources and devices | Event timeline | Event inspector
                    | Viewer -> App control composer
```

Exactly one current runtime or historical recording is selected at a time. The timeline can merge
one through sixteen selected devices inside that source. Events from different recordings are
never merged because their monotonic clocks and lifecycle boundaries are independent.

## Time and ordering semantics

NearWire captures one Viewer wall time and one Viewer monotonic receive time when an Event commits
at the protocol boundary. The live projection and durable store share that same observation; the
store does not sample a second receive time later.

The authoritative order inside a recording is:

```text
(Viewer receive monotonic time, durable Event row ID)
```

This makes a merged timeline independent of inaccurate or changing phone clocks. The inspector
shows the App-created wall time, App-origin monotonic time, and Viewer receive wall time as separate
values. NearWire does not silently rewrite one into another.

A Viewer-to-App draft does not enter recorded history when the operator presses Queue. It becomes a
normal downlink timeline row only after the secure transport mailbox admits it. A rejected,
expired, disconnected, encoding-failed, or otherwise unadmitted draft is not presented as sent
history.

## Live and recorded rows

The current runtime stays useful during storage startup, migration, or failure through a bounded
in-memory live projection. A live row that has not been confirmed durable is labeled
`Not recorded`.

- A recorded row is owned by the local SQLite store and participates in durable search, history
  operations, retention, and export.
- A `Not recorded` row is memory-only. It is not exported, restored after restart, replayed into an
  App, or backfilled into SQLite after it leaves the live window.
- When the exact durable row becomes visible, the timeline reconciles it with its live counterpart
  by exact runtime, connection, direction, and wire sequence. It does not merge by peer Event UUID.
- Store recovery affects future persistence. It does not claim that already-evicted transient
  content became durable.

### Source and device materialization

The current source can appear as `Live — not recording` before the store creates its recording.
Likewise, a connected App can appear before it has a durable device row. Live matching always uses
the logical runtime and connection identities.

Durable queries start only when the current runtime has an exact durable recording mapping. For a
partly materialized device selection, SQL includes only the exact mapped device rows while the live
matcher continues to cover every selected logical device. NearWire never invents a database ID,
silently drops a selected-device restriction, widens the query to All Devices, or substitutes a
different runtime. Materialization triggers one fresh bounded traversal while preserving the
logical device selection.

Historical recordings are explicit operator selections. `All Devices` within one materialized
recording uses the recording scope directly and does not require the Viewer to enumerate every
reconnect as a predicate.

## Duplicate horizon and completeness indicators

Duplicate classification uses the exact key:

```text
(runtime logical ID, connection ID, direction, wire sequence)
```

The peer-provided Event UUID is content and is not a uniqueness key. Within the bounded live
horizon, an identical value is idempotent and a conflicting value preserves the first value and
adds a `Conflict` diagnostic. Comparison covers the persisted Event projection and initial
disposition. Session aliases, deterministic accounting, and newly sampled receive times do not
replace the first observation's values.

The callback ingress owns at most 64 records and 20 MiB of deterministic accounted data. The live
window owns at most 512 records and 32 MiB. After an exact key leaves that window, the durable row,
if one exists, remains the duplicate authority. If both live history and durable storage have lost
the first value, NearWire makes no global first-wins or exactly-once claim. Overflow and forgotten
identity horizons are disclosed through bounded gap counters instead of an unbounded tombstone set.
Conflict markers remain resident only while their exact connection remains in the live projection.
Direct-to-managed reconciliation, normal ended-session reclamation, and terminal capacity eviction
remove detached markers and increment diagnostic loss for each marker whose evidence can no longer
be presented.

`Gap`, `Drop`, `Conflict`, `Session ended`, and `Not recorded` are independent states. They are not
proof that every Event before or after the marker is missing.

### Diagnostic gap lane

Gaps are diagnostics, not fabricated Events. They appear in a separate `Diagnostic Gap Lane`,
ordered by Viewer wall-time range and scoped to the selected recording and devices. A gap marker
shows its scope, direction, count, range, and reason. Overlapping gap identities remain separate,
and a newer revision appears only after a fresh traversal.

The lane loads at most 32 markers per page and retains at most 128. A drop remains a badge/filter
signal; it is never converted into a peer Event. Because gap evidence is bounded, it describes
known incompleteness without claiming a complete reconstruction of everything that was lost.

## Search and filters

The Explorer supports exact or prefix Event type, literal content, full text, App and Bundle
identity, direction, priority, receive-time range, selected devices, typed JSON path/value,
presence, gap, drop, and terminal-disposition filters. Different dimensions combine with AND;
multiple selected values inside one dimension combine with OR.

Search text is capped at 512 UTF-8 bytes. A filter can contain at most 32 predicates and can select
at most 16 devices. Invalid or over-broad work returns fixed validation or refine guidance; it does
not silently widen the query or publish a partial result as complete.

Full-text search is intentionally durable-only. It uses the store's indexed FTS5 tokenizer. During
a storage outage, transient rows are excluded and the Viewer reports:

```text
Full-text search requires recorded data — transient rows excluded.
```

NearWire does not imitate FTS tokenization in Swift. A transient row participates normally after
that exact row becomes durable.

## Pause, scrolling, and refresh

`Pause` freezes presentation only. It invalidates outstanding page, detail, live-match, and renderer
results before preserving the current rows, selection, and scroll anchor. It does not pause:

- network receive or the secure session;
- directional rate control or Event queues;
- live-window admission or durable persistence;
- store cleanup or migration;
- Viewer-to-App queue admission or sending.

While paused, the model keeps only the latest change token, latest durable upper bound, and bounded
change counters. It creates no task per arriving Event. `Resume` releases the old traversal and
starts one fresh bounded snapshot with the current source and filters. `Jump to Latest` starts a new
tail traversal. Manual scrolling disables auto-follow but is not Pause.

When active, refresh is latest-only: at most one scheduled wake, no more than ten refreshes per
second, and no more than one per main run-loop turn. Pause schedules no refresh wake.

## Resident and work bounds

The Viewer keeps presentation memory bounded independently of total history:

| Resource | Resident maximum |
|---|---:|
| Recording rows | 200 |
| Device rows | 200 |
| Event rows | 600 |
| Gap markers | 128 |
| Selected devices | 16 |
| Selected Event/detail | 1 |

Recording pages default to 50 and allow at most 100 rows. Device pages default to 100 and allow at
most 200. Event pages default to 100 and allow at most 200. Gap pages allow at most 32. Paging uses
frozen keyset cursors, not `OFFSET`; loading one edge evicts the opposite edge and retains a bounded
reload marker. An evicted selection never causes an unrelated row to be selected.

Catalog, Event, gap, and causality operations are cancellable and use bounded SQLite work and
short transactions. Catalog, gap, and causality work is capped at 2,000,000 SQLite virtual-machine
steps and a 250 ms logical deadline. Live evaluation scans at most 512 entries/32 MiB, 16,384
predicate checks, and 1,000,000 JSON nodes with a 100 ms logical deadline. Exhaustion returns
refine guidance and no partial-complete publication.

These logical deadlines are cancellation and work gates, not wall-clock service-level guarantees.
Machine load, storage, history shape, and operating-system scheduling can change elapsed time.

## Inspector and renderers

The inspector retains one canonical Event content buffer. Raw JSON is navigated in 64 KiB chunks
without creating one unbounded accessibility string. Pretty JSON accepts at most 1 MiB of input and
2 MiB of derived output. The JSON tree materializes at most 4,096 visible nodes, expands at most 128
children at a time, and bounds previews and focused accessibility text.

The built-in immutable renderer registry selects by Event type:

- `log.*` prepares bounded message chunks;
- `table.*` prepares bounded scalar rows and pages;
- `chart.*` prepares a one-Event numeric inspection series;
- `timeline.*` supplies compact timeline rows;
- every other type uses Generic JSON.

Specialized rendering accepts at most 1 MiB for log/table input and uses independent scan, row,
derived-text, and 100 ms logical work bounds. Numeric inspection scans at most 200 rows/8 MiB and
retains at most eight finite numeric fields and 200 points. An incompatible shape, limit, timeout,
or preparation failure falls back to Generic JSON with fixed guidance. Renderer failure cannot fail
the query, store, or session.

Untrusted structured labels and accessibility text escape C0/C1 controls and bidirectional-format
characters as explicit code-point tokens. This prevents content from changing the visual direction
or structure of labels. The Raw surface remains the explicit exact-content view. Received or
stored Event content has no copy, cut, drag, share, or clipboard-export command.

## Causality

Causality is an inspection aid, not a uniqueness guarantee. Lookup stays inside the selected
recording, exact device session, frozen Event snapshot, and query lease. It reads at most nine rows
for one peer UUID so it can show eight candidates plus `hasMore`, and breadth-first expansion stops
at 32 nodes.

- No candidate is `Missing`.
- One candidate is linked directly.
- Multiple candidates are `Ambiguous` and require operator interpretation.
- `replyTo` edges are visited before `correlation` edges.
- Durable row ID, not peer UUID, is used for cycle detection, so UUID reuse does not manufacture a
  false cycle.

## Recording operations and JSON export

Rename, note, append-only annotation, pin/unpin, and delete remain store-authoritative. Each edit is
revision-bound. An active or read-leased recording cannot be deleted. Delete requires a fresh token
bound to the current recording and annotation revisions; a stale or expired confirmation changes
nothing and refreshes the catalog.

Export supports `Complete Recording` and `Current Filtered Result`. Preflight freezes the exact
scope and recorded Event count before the save panel opens. Transient `Not recorded` rows are
always excluded. The operator must review all of these facts:

- Event content and metadata may contain sensitive data.
- The JSON file is unencrypted.
- `device-N` and `connection-N` aliases are pseudonyms, not redaction.
- The file is outside Viewer quota, retention, cleanup, and automatic deletion.
- The selected destination or its provider may synchronize or back up the file.
- NearWire does not remember the destination.

Export writes bounded chunks to an owner-only temporary file and atomically replaces the selected
destination only after the complete JSON document commits. Cancellation before that commit
preserves an existing destination. After the operator requests cancellation, Viewer shows a
`Cancelling` state until the export owner reports which side of that boundary won; it does not claim
that the prior file was preserved prematurely. Once the atomic replacement commits, that successful
file result is authoritative even if a cancellation or runtime replacement reaches the operation
wrapper before its callback. A completed export is an ordinary external file and remains the operator's
responsibility.

There is no Event clipboard export, automatic export, CSV, import, `.nearwire` archive, remembered
destination, or cloud synchronization feature.

## Viewer-to-App control composer

The composer is memory-only and accepts one through sixteen currently active targets. It validates
one Event type, ordinary JSON content, priority, TTL in milliseconds, and either `Normal` or
`Keep Latest` queue policy.

- Event type is limited to 128 UTF-8 bytes. User-entered `nearwire.*` platform types are rejected.
- JSON editor capacity is the most conservative value derived from the Viewer 16 MiB hard model
  bound and the active negotiated content/model bounds. Each edit is rejected before storage if it
  would exceed the displayed limit.
- TTL accepts one through nine ASCII digits, with no sign or spaces. It must be between 1 and the
  active maximum; the protocol hard maximum is 604,800,000 ms.
- `Keep Latest` uses the canonical Event type as its queue-local replacement key.
- The draft is parsed and encoded once, then the session manager performs an independent bounded
  admission decision for each exact target. Multi-target admission is not atomic and never
  retargets a reconnect.

Per-target results are `Queued locally`, invalid target, no longer connected, not active, or queue
rejected. `Queued locally` means only that the exact active session's local bounded queue accepted
the draft. It does not mean delivered, received, acknowledged, executed, or processed. Disconnect
may clear an already accepted queue item before transport admission.

The two directional session queues each hold at most 5,000 Events and 16 MiB, subject to the
negotiated single-Event limit and rate. A zero business rate pauses that direction without stopping
protocol control or cleanup. The composer does not retry, persist, or maintain templates,
favorites, or an independent send history. A downlink Event appears in ordinary durable history
only after secure-mailbox admission.

## Storage schema update and recovery

An existing schema-1 store is updated to schema 2 by adding three indexes for scoped causality and
gap ordering. Event content is not rewritten. The Viewer performs this resource-governed update on
a background writer before opening normal query and export readers.

Operator-visible phases are limited to:

- `Preparing history update`
- `Updating history index 1/3` through `Updating history index 3/3`
- `Validating history update`
- `Migration needs more disk space`
- `Migration cancelled`
- `Migration failed`

The update uses the system SQLite VFS and a verified private process temporary directory. Before
the transaction, both the database and temporary volumes must have checked available capacity of
at least 512 MiB plus six times the database, WAL, and shared-memory allocated footprint. During
work, a 256 MiB remaining-space floor is enforced. NearWire does not change process-wide SQLite or
environment temp routing.

Networking and the bounded live projection can continue while persistence, durable search, and
export are unavailable. Automatic migration is attempted at most once per process. It never spins
after cancellation, insufficient space, or failure. After correcting the condition, use `Retry
Storage`, or relaunch the Viewer, to start a new generation. A failed update rolls back to an intact
schema 1 and publishes no partial schema 2. Success closes the migration writer and opens freshly
hardened normal writer/readers before storage becomes available.

History retention and Event TTL are different. Retention controls how long already-recorded local
history remains eligible for cleanup. Event TTL controls transport eligibility and does not extend
or shorten Viewer history retention.

## Accounting and performance interpretation

NearWire's stated queue and live-window byte caps are deterministic accounting limits over encoded
Event data and fixed ownership overhead. They are not promises about Swift heap use. The Viewer
also bounds record counts, pages, cursors, tasks, retained buffers, operation tokens, SQLite VM
steps, and generation ownership; those structural limits are the portable release gates.

Whole-process heap high-water, callback wall time, migration duration, and similar measurements are
diagnostic machine context. They vary with hardware, valid history size, filesystem behavior,
system load, and compiler/runtime versions. They must not be interpreted as actual-device latency,
memory, or throughput guarantees.

## Privacy and lifecycle cleanup

Event content is deliberately visible only in the explicit timeline, selected inspector, composer,
filter, and recording-metadata editing surfaces. Safe device rows, pending/recent rows, queue
telemetry, recovery errors, preferences, logs, analytics, reflection, and restoration state remain
content-free. Content-bearing models use redacted descriptions and reflection.

Standard copy, cut, and paste remain available in operator-owned editable inputs. Paste is checked
against the same pre-storage limits. NearWire performs no background pasteboard read, monitoring,
custom clipboard history, or content restoration. The selected Event inspector is intentionally
read-only and has no clipboard or share action; JSON file export is the separately disclosed data
release boundary.

Window close, runtime replacement, listener failure, retry, TLS reset, full identity reset, and
termination first stop new Explorer/composer work, then cancel and join accepted catalog, query,
gap, causality, detail, live-match, renderer, export destination, export execution, and composer
operations. Cleanup clears live
content, filters, validation text, selections, canonical detail, derived renderer and accessibility
values, composer fields/results, and subscriptions before a replacement runtime may use those
surfaces. Each controller operation has one cancellation/delivery handoff, and Store replacement
invalidates the predecessor generation before a successor can publish. Renderer and composer
preparation results converge into separate latest-only pumps that retain at most one processing and
one pending value, schedule at most one MainActor successor, and release displaced content outside
their locks. Their cleanup joins both background preparation and the final pump drain. The native
save panel is likewise one controller-owned cancellable operation; closing the export flow or
runtime dismisses it, and a later AppKit response cannot mutate or retain the old explorer. Store
traversal release, query replacement, tail page, and gap work retain their exact Store token; an old
stage cannot apply or continue on a replacement Store. The exact export terminal receipt remains
owned until its commit-boundary result arrives, so pre-commit cancellation and committed success are
reported truthfully. Store shutdown also deactivates and joins the coalesced status provider before closing SQLite. Late
callbacks cannot repopulate cleared state. A fresh runtime contains no prior transient or composer
content.

Recorded history and saved recording metadata remain store-owned and are not erased merely because
the runtime UI closes. A JSON export that already committed is outside Viewer ownership.

## V1 exclusions

The Event Explorer and composer do not provide:

- cross-recording merged timelines, App replay, Event acknowledgement, RPC, or delivery claims;
- performance dashboards, long-range metric aggregation, or synchronized charts;
- third-party renderer plugins, dynamic bundles, JavaScript, or arbitrary code execution;
- templates, favorites, automatic retry, or independent Viewer-to-App send history;
- import, CSV, `.nearwire` archives, automatic export, cloud synchronization, or destination
  persistence;
- raw SQLite, SQL, filesystem paths, transport errors, or internal errors in operator UI;
- received/stored Event copy, drag, share, clipboard export, or background clipboard monitoring.

Performance dashboards are planned as a separate Viewer capability. The current `chart.*` renderer
is only a bounded one-Event inspection aid.
