## Context

`viewer-multidevice-flow-control` owns active protocol sessions, bounded queues, directional rate
policy, and typed telemetry. `viewer-local-store-search` owns automatic recording, SQLite,
retention, search compilation, keyset Event pages, exact detail loading, revision-safe recording
operations, and streaming export. Their ownership boundaries are already reviewed and must remain
intact.

The current root view presents a device sidebar and one device-telemetry detail. The live runtime
wires the session manager to the store journal but intentionally discards the optional uplink
consumer. Store query/export services are internal to a coordinator and are not yet exposed through
the application dependency boundary. The next UI therefore needs Viewer-only service facades and
presentation state; it does not need a new transport, Event model, database, or Core abstraction.

## Goals / Non-Goals

**Goals:**

- Make current and historical Event data inspectable through one native three-column workspace.
- Preserve exact recording scope, receive-time ordering, bounded keyset work, and safe cancellation.
- Keep recorded/received Event content out of logs, reflection, `UserDefaults`, safe status, recent
  disconnect rows, and clipboard export while deliberately showing it in the selected inspector.
- Keep the UI useful during storage failure through a small bounded transient live window.
- Make pause a presentation choice, never a transport, queue, or persistence switch.
- Compose downlink control Events through the existing session queues with honest local-admission
  wording and unified durable timeline history after transport admission.
- Expose the already-designed recording operations and export flow without weakening their
  revision, lease, disclosure, or filesystem contracts.

**Non-Goals:**

- Cross-recording merged timelines, App replay, Event acknowledgement, RPC, or delivery claims.
- Performance projections, metric cards, synchronized long-range charts, or bucketed aggregation.
- Third-party renderer installation, dynamic bundles, JavaScript, templates, favorites, or a
  separate recent-send history.
- Import, CSV, `.nearwire` archives, cloud synchronization, recorded-Event clipboard export or
  monitoring, or raw
  SQLite/SQL/path/error presentation.
- New public SDK APIs or Core/SDK dependencies on AppKit, SwiftUI, SQLite, or Viewer types.

## Decisions

### 1. One factory creates one runtime-scoped component bundle

`ViewerApplicationModel` remains the `MainActor` root, but it never constructs independent session,
journal, live-window, or control objects. `ViewerRuntimeDependencies` exposes one
`makeRuntimeComponents(runtimeLogicalID:)` factory called exactly once by each `startRuntime`.
It returns one Viewer-internal `ViewerRuntimeComponents` bundle containing:

1. the exact `ViewerAdmissionHandoffOwning` instance used by admission;
2. a typed `ViewerSessionControlling` facade for that same manager, with no concrete downcast;
3. the one `ViewerLiveEventWindow` and read-only live observation facade;
4. one composite journal wired to that live window and the process-lifetime `ViewerStoreRuntime`;
5. one manager/runtime generation used by every control-target token; and
6. the explorer inputs and finite cleanup receipt for that exact runtime logical ID.

The process-lifetime `ViewerStoreRuntime` remains outside the per-runtime bundle so sequential
Viewer runtimes can reopen the same local history. The manager receives the factory's explicit
runtime logical ID rather than generating a hidden second ID. The composite journal forwards one
normalized already-validated observation to store and live projection; it cannot call a decoder,
sequence counter, mailbox mutation, token bucket, terminal gate, or SQLite on the protocol callback.
The session manager remains the only downlink queue owner and the store remains the only durable
source.

Every stop path—window close, application termination, listener failure, TLS reset, and full
identity reset—uses one order. It first seals explorer/control admission and invalidates all
presentation subscriptions/generations. It then starts the explorer cleanup receipt and the
existing admission/session shutdown. Session drain owns already queued downlink Events. After the
last session ends, composite-journal `runtimeEnded` finishes the exact store runtime and clears the
live window before the existing receipt completes. The application awaits the explorer receipt and
existing admission receipt as one combined bounded cleanup; it creates no second protocol cleanup
owner.

Tests inject the bundle/facade protocols, prove one bundle per runtime and exact identity wiring,
and never depend on casting a fake handoff owner. No singleton or global mutable registry is added.

### 2. The window uses a stable three-column information architecture

The content area is one three-column split view with a bottom composer spanning the timeline and
inspector region:

```text
Sources and devices | Event timeline | Event inspector
                    | Viewer -> App control composer
```

The left column contains the current live context, keyset-paged historical recordings, recording
name/state/pin/gap hints, and the devices for the selected recording. Pairing, pending approval,
Pause New Devices, device nickname/rates/telemetry, storage settings, and identity reset remain
reachable in a compact workspace/settings area rather than being duplicated in Event rows.

Exactly one recording context is selected. `ViewerExplorerScope` is the Viewer-internal,
source-neutral authority. Its source is either `.currentRuntime(runtimeLogicalID)` or
`.historicalRecording(recordingID)`, and its device scope is either `.all` or 1 through 16 exact
device logical IDs. A current device logical ID is its connection ID; a durable device catalog
exposes the same `DeviceSessions.logicalID`. All Devices compiles without a device predicate and
therefore does not require materializing every reconnect row. V1 never combines Events from
different recordings because their monotonic clocks and lifecycle meanings are independent.

The current runtime appears even before storage materializes a recording. That source is labeled
`Live — not recording` while unavailable. A separate immutable materialization snapshot maps the
current runtime logical ID and any materialized connection IDs to positive durable recording/device
row IDs. The live matcher always uses logical IDs. A durable query is issued only for the mapped
recording and mapped selected devices; if selected devices are only partly materialized, the SQL
predicate contains only those exact mapped rows while live matching still covers every selected
logical ID. It never substitutes a synthetic row ID, drops a selected-device predicate, or admits a
different runtime. Once the same logical runtime receives a durable row, one presentation-generation
transition updates the mapping, rebuilds the durable traversal, preserves the logical device
selection, and reconciles exact journal keys. Historical source selection remains a distinct explicit
operator action.

### 3. Store routing and query ownership remain coordinator- and operation-exact

Application code receives one `ViewerStoreExplorerGateway` owned by `ViewerStoreRuntime`; it never
retains `ViewerStoreCoordinator.Services`. Each catalog/query/detail/gap/causality/mutation/export
request receives an immutable token containing the current coordinator generation and operation
UUID. The runtime acquires an originating-coordinator operation lease before returning the request.
Coordinator replacement seals that generation, rejects new work, cancels its exact active tokens,
joins its bounded operations, and releases leases against the originating registry before closing
SQLite. Internal operation/cancellation ownership is retired before arbitrary client rejection
code. Replacement transitions are serialized independently from the generation-state lock: each
transition detaches and seals its predecessor, publishes exactly one successor, releases transition
ownership, and only then invokes deferred arbitrary callbacks. A callback may therefore reenter
sealing or installation without self-join or transition-lock deadlock, and an external installation
cannot overwrite an unsealed callback-installed generation. Late work fails with one closed
`storeReplaced` presentation category and never retargets itself to a replacement coordinator. Fresh
work explicitly acquires the currently published generation. The immutable operation token also
shares one generation-validity cell. Replacement invalidates that cell before successor publication,
so a client callback that already claimed delivery can retire its exact controller work identity but
cannot apply the predecessor's catalog, detail, mutation, or ordinary export result on the
MainActor. The traversal coordinator preserves that token at release, query replacement, tail page,
and gap stages. Each successor request must follow the preceding token on the same still-published
Store generation; a retired predecessor neither updates presentation nor dynamically routes its next
stage to the replacement. If replacement wins after a handler validates its predecessor but before
successor submission, the synchronous `storeReplaced` response carries an explicitly
delivery-invalid token. The callback still retires its exact work identity but publishes no error or
other presentation state.

One non-MainActor `ViewerExplorerQueryArbiter` is the sole mutable owner of the current
`ViewerEventTraversal` and its refreshed value lease. Page, detail, gap, causality, and filtered-
export scope creation serialize through it; source replacement ends the traversal exactly once.
Catalog work also serializes through the same interactive reader but does not touch the traversal.
Every interactive-reader request has an enqueue-to-completion operation token. Cancellation removes
a queued matching token or interrupts only the same active token; a completed/superseded token is a
no-op and cannot interrupt its successor.

Filtered export does not transfer a mutable query lease. Under the arbiter, the current query and
frozen upper bounds become one immutable `ViewerFilteredExportScope`; export then acquires its own
finite export lease on the export reader. Export and later timeline paging therefore share frozen
semantics without concurrently refreshing one query lease.

Recording pages contain 1 through 100 rows, default 50, and use immutable descending recording row
ID. Device pages contain 1 through 200 rows, default 100, and use connection ordinal plus row ID.
Each catalog cursor binds its query fingerprint, store generation, upper base/version/tombstone row
IDs, direction, and change generation. Any catalog-affecting store change invalidates and restarts
the catalog from the first page; no cross-change no-omission claim is made. Within one unchanged
snapshot, new rows/revisions are excluded and cursor continuity is exact. Neither catalog uses
`OFFSET`, a long transaction, or Event content.

One immutable `ViewerExplorerFilter` plus `ViewerExplorerScope` is authoritative for presentation
and live evaluation. It carries no SQL and no synthetic database IDs. When a materialization
snapshot contains the required durable IDs, the query arbiter compiles that value into the existing
SQL-only normalized `ViewerEventQuery`; when no selected device has materialized, it issues no
durable Event query rather than compiling All Devices. Different dimensions use AND and multiple
values inside one dimension use OR. SQL syntax, raw FTS, dynamic JSON functions, and unvalidated
ordering never originate in UI state.

### 4. Event order is durable receive order; diagnostics stay visibly distinct

Persisted Event rows retain the existing `(viewerMonotonicNanoseconds, eventRowID)` keyset order.
That is the authoritative single/merged Event ordering inside one recording and is independent of
phone clocks. The inspector separately displays the App-created wall time, App monotonic value, and
Viewer receive wall time; none is silently rewritten.

Gap records are not fabricated Events and are never inserted into the monotonic Event order. The
timeline owns a separate diagnostic lane bound to the exact Event traversal lease, device filters,
and frozen `gapUpperRowID`. It pages 1 through 32 latest-revision markers by
`(lastViewerWallMilliseconds, gapRowID)`, retains at most 128, and displays their Viewer wall-time
range, device scope, direction, count, and closed reason. Stable identity is
`(recordingID, optional deviceSessionID, namespace, sequence)`; overlapping identities remain
separate and later revisions above the frozen bound wait for a fresh traversal. Drop presence
remains a filter/badge and is never converted into a peer Event.

Downlink rows enter the durable timeline only after secure-mailbox admission, exactly as the store
already defines. A successful composer enqueue is not inserted into history early. Invalid,
expired, route-dropped, encoding-failed, or mailbox-rejected drafts therefore cannot appear as sent
Events.

### 5. A two-stage bounded live projection covers storage outages

One immutable `ViewerCommittedEventObservation` is created at each protocol commit and shared by
store and live paths. It captures one Viewer wall/monotonic receive time, runtime/connection ID,
bounded frozen App/Bundle/display aliases, Event value, deterministic encoded byte count, direction,
wire sequence, and initial disposition. The store no longer samples a later Viewer wall time for
that Event.

Duplicate equivalence uses one canonical durable projection that both live ingress and the writer
can represent. The exact key supplies runtime/connection/direction/sequence. Compared values are
Event ID/type, canonical content JSON bytes, App-created wall time normalized once to
`Int64((secondsSince1970 * 1,000).rounded())`, App monotonic time, priority, TTL, schema version,
correlation/reply IDs, and initial disposition. Source, target, and session epoch are excluded because
the transport/session boundary validates them against the exact session before commit; a mismatch
cannot enter either journal path. Frozen aliases/session metadata, deterministic byte accounting,
and newly sampled Viewer receive wall/monotonic times are also excluded; the first observation's
accounting and receive times remain authoritative. Comparison is field/byte exact and never trusts a
hash alone. The composite journal
linearizes duplicate classification by offering the observation to the live
ingress identity index before either fan-out effect. While an exact key is pending in ingress or
retained in the live window, an identical value is idempotent and a conflicting value preserves the
first and creates one conflict marker without reaching the store. Once a key is evicted, the live
authority deliberately forgets it and its existing overflow marker discloses that the transient
identity horizon was lost. A later value is treated as a new transient candidate. If a durable row
already exists, the writer performs the second bounded authority check: identical is a no-op;
different content preserves the immutable row, returns a typed content-free `journalConflict`
outcome to the projection executor, and does not make the store unavailable. A durable `identical`
outcome removes only the later exact transient candidate; `journalConflict` removes that later
candidate and adds the bounded conflict marker, so neither can obscure the first durable row. If neither live nor
durable authority retains the first value because storage was unavailable, no global first-wins
claim is made after eviction.

If the live ingress rejects a new key at its count/byte bound, it records the saturating ingress gap
and returns `untracked`; the composite journal still submits that observation to the serial writer.
Writer order then provides the only duplicate authority for durable data. If storage is unavailable
too, the observation is intentionally represented only by the gap and no duplicate guarantee is
claimed for its forgotten content.

A conflict marker is keyed by exact runtime/connection/direction/wire-sequence plus
`presentationConflict`, coalesces only while that bounded marker remains resident, and otherwise
increments the same saturating diagnostic-loss counter. Pending, drained, durable, unavailable,
recovered, evicted, and shutdown states therefore have an explicit outcome without an unbounded
runtime key set. Every connection-retirement path, including direct-to-managed reconciliation,
ended-session reclamation, and terminal capacity eviction, removes that connection's detached
markers and increments diagnostic loss for each marker that can no longer remain resident.

The protocol callback offers observations to a 64-record/20-MiB fixed ingress ring using
precomputed deterministic Event bytes plus fixed maximum metadata/entry overhead. The 20-MiB bound
is sized to admit one maximum legal encoded journal Event together with that maximum fixed overhead;
it is not described as a Swift-heap bound. Admission performs a constant number of index/ring
operations, never evicts or releases a large Event while holding the callback lock, and either
admits or increments one saturating ingress-gap counter. At most one serial projection drain plus
one dirty successor exists. Off the protocol callback, that worker maintains the 512-record/32-MiB
window with an O(1) deque and exact-key index, releases displaced values outside its state lock, and
publishes one immutable snapshot generation. Actual heap is measured separately from deterministic
accounted bytes.

The exact transient key is `(runtime logical ID, connection ID, direction, wire sequence)`. Peer
Event UUID is content and is never used for deduplication. New durable device materialization SHALL
store the exact admission `connectionID` in the existing `DeviceSessions.logicalID` column instead
of accepting that store API's current random default. Persisted query rows expose that logical
ID/direction/sequence identity so the presentation merge removes a transient entry only when its
exact durable row is visible. Pre-existing closed rows need no migration because they have no live
transient counterpart. Transient-only rows are labeled `Not recorded` and are never exported or
retroactively claimed durable.

The projection also owns at most 16 frozen session alias/App/Bundle records, exact later
`uplinkTerminated` dispositions, one positive-drop flag/cumulative sample per device, session end,
projection overflow/conflict gaps, and store unavailable/recovery gap state. The process store feeds
content-free accepted/identical/conflict, unavailable, and recovered transitions to the projection executor; accepted waits for exact durable visibility, identical removes only the later exact transient candidate, and conflict removes that candidate plus adds its bounded marker. That
status path never calls back into protocol state and cannot change the already committed observation.
`hasGap` applies when a runtime gap or the Event's exact device gap exists; `hasDrop` applies when the
exact device has a positive drop sample; `hasTerminalDisposition` applies only to that Event. Missing
projection data never counts as a match. Evaluation consumes one immutable snapshot and never reads
mutable session state mid-query.

At most one latest-only refresh wake exists, at most 10 times per second and no more than once per
main run-loop turn. One cadence performs at most one query/live refresh. Pause schedules none.
Window overflow evicts oldest entries on the projection executor and increments one coalesced UI
gap. Runtime shutdown joins the drain and clears all Event/session projection content. Recovery does
not backfill transient content into SQLite.

### 6. Pause freezes presentation, not acquisition

Pause first increments the single presentation generation, invalidating page/detail/live/renderer
completions, and only then freezes the currently rendered rows, selection, and scroll anchor. It does not pause session
receive, directional token buckets, queues, store ingress, SQLite, cleanup, the live window, or
downlink sending. While paused the model stores only one latest change token, the newest durable
upper row ID, and a saturating transient-change count; it creates no page/query task per Event.

Source/filter/Pause/Resume/Jump to Latest all use the same generation state machine. Resume asks the
query arbiter to release the stale traversal exactly once and starts one fresh snapshot query with the current scope and
filters. It reconciles exact live keys, restores the nearest still-visible selected row when
possible, and otherwise selects no unrelated row. If transient overflow or a durable store gap
occurred, the UI shows that diagnostic instead of implying a complete interval.

Manual scrolling disables auto-follow but is distinct from Pause. A `Jump to Latest` action starts
one new tail traversal. Clearing filters similarly starts one bounded traversal and never asks an
App to resend data.

### 7. Detail and renderer work is bounded, internal, and fallback-safe

Event detail adds schema version, TTL, origin monotonic time, Viewer receive time, Event ID,
direction/sequence, priority, resolved local disposition, device aliases, correlation ID, and
reply-to ID to the existing canonical content. JSON parsing and pretty printing occur off the
MainActor. One inspector retains at most one canonical Event data buffer. Raw JSON is decoded in
64-KiB navigable chunks without constructing one full accessibility string. Pretty output is
limited to 1 MiB input, 2 MiB derived bytes, and 100 ms; larger content stays in chunked raw mode.
The tree retains shared paths/ranges rather than copied values, loads at most 128 children per
expansion, materializes at most 4,096 visible nodes, 2 MiB derived text, 256 preview bytes per node,
and 512 accessibility bytes for the focused node. Every preparation is generation-cancellable.

The internal `ViewerRendererRegistry` registers immutable pattern entries ordered by specificity:

- `log.*` accepts one canonical Event of at most 1 MiB for structured rendering, reads one string or
  scans at most 4,096 top-level entries/1 MiB/100 ms for one string `message`, emits at most 64 KiB
  in 4-KiB visible chunks, and exposes at most 512 bytes for the focused accessibility value;
- `table.*` accepts one canonical Event of at most 1 MiB, scans at most 4,096 top-level entries/1 MiB/
  100 ms, pages 64 scalar rows, retains at most 128 row descriptors and 512 KiB derived text, limits
  key/value previews to 256/1,024 bytes and focused accessibility text to 512 bytes, and reports
  `hasMore` rather than copying complete values;
- `chart.*` streams at most one Event detail at a time, scans at most 200 rows/8 MiB/100 ms, and
  retains at most eight finite numeric fields and 200 scalar points but no full content page;
- the timeline renderer supplies compact Event rows; and
- `*` always resolves to Generic JSON.

A type-pattern match whose content shape is incompatible or exceeds those limits falls back to
Generic chunked JSON with fixed guidance. Log/table labels visibly isolate untrusted content;
C0/C1 controls and bidirectional-formatting scalars are rendered as explicit escaped code-point
tokens in structured labels and accessibility text, while the exact content remains available only
through the raw surface. No renderer retains copied full values beyond the one canonical detail
buffer. Renderer failure changes only the inspector state and cannot fail the query or session.
Registry mutation and third-party bundle/plugin loading are absent in V1. The numeric renderer is a
visible-window inspection aid, not the performance projection/dashboard scheduled next.

Causality lookup remains inside the selected traversal's recording, exact device session, lease,
and frozen Event upper row ID. Candidate rows are ordered by durable row ID; the query reads at most
nine so it can return eight plus `hasMore`. Breadth-first expansion visits `replyTo` before
`correlation`, uses durable row ID—not peer UUID—for its visited/cycle set, and stops after 32
nodes. Zero matches display `Missing`, one displays a link, and several display `Ambiguous`; reused
UUIDs do not become false cycles.

### 8. Recording operations and export preserve store authority

The explorer exposes recording rename, note, annotation, pin/unpin, and manual deletion through the
existing bounded validators and writer ordering. An active recording cannot be manually deleted.
Delete UI first requests a token bound to the current recording and annotation revisions, then
shows one explicit confirmation; a stale/expired token changes nothing and refreshes the catalog.

Export supports Complete Recording and Current Filtered Result. The model requests preflight data,
shows the existing unencrypted/pseudonym/content/sync disclosure, and only after confirmation opens
the native save panel. Destination selection is one controller-owned lifecycle operation with an
exact cancellation/delivery gate and weak controller capture. Closing the flow or runtime cancels
the panel and joins a response that already claimed delivery; a later AppKit response is a no-op and
cannot retain or repopulate the sealed explorer. The export service retains its one lease, bounded pages, cancellation,
nonsymlink temporary file, and atomic replacement. The UI never receives a database path, SQL
error, temporary path, or raw internal error. Controller cancellation moves to a content-free
`cancelling` state and retains the exact export operation and delivery identity until the gateway
reports which side of the irreversible commit boundary won. Pre-commit cancellation remains
cancelled and preserves the old destination. A successful export result means atomic replacement
already committed and remains authoritative if generic cancellation or coordinator replacement
arrives before gateway result delivery. This exact terminal export receipt is the narrow exception
to predecessor-generation presentation rejection: it cannot read from or launch work on the
successor generation, and runtime sealing may still join and clear it without repopulating the
sealed controller.

There is no import, CSV, `.nearwire`, auto-export, or export destination persistence.

### 9. The composer validates once and reports per-target local admission

The composer stores text through incrementally accounted buffers capped before parse: Event type
128 UTF-8 bytes; JSON content
`min(active maximumEncodedContentBytes, (min(active maximumEncodedModelBytes, 16,777,216) - 65,536) / 4)`
bytes using checked nonnegative arithmetic; search 512 bytes; JSON path 256 bytes; JSON comparison
text 16 KiB; name 80 scalars/120 bytes; note/annotation 4,096 scalars/16 KiB. The JSON formula reserves
the Core compact-tag/envelope expansion and the Viewer hard single-Event limit; smaller negotiated
per-target limits remain authoritative `queueRejected` decisions. TTL uses a bounded numeric editor
backed by `UInt64`; its adapter accepts at most nine ASCII digits, no sign/space, and only
`1...active maximumTTLMilliseconds` (whose Core hard maximum is 604,800,000). The text coordinator
applies edit-range byte/scalar deltas and does not rescan a maximum buffer on every keystroke. The
composer selects 1 through 16 currently active targets and accepts Event type, ordinary JSON
content, priority, TTL milliseconds, and `.normal` or `.keepLatest`. Parsing and deterministic
validation use one replaceable off-MainActor generation and the existing Core `EventDraft` limits. It produces one immutable
`ViewerPreparedControlEvent` containing the validated draft, one encoded/accounted byte count, and
one validated normal/keep-latest policy; target admission never re-encodes, traverses, or deep-copies
the content. User-entered reserved
`nearwire.*` types are rejected; platform Event types remain owned by built-in features.

For keep-latest, the canonical Event type is the queue-local key. This keeps the V1 form simple and
ensures repeated control state of one type coalesces predictably without a second arbitrary key
field. The manager issues one opaque, memory-only target capability for each exact connection. It
contains a random token UUID, exact runtime logical ID, manager generation, and connection ID and
cannot be reconstructed or persisted by the UI. Duplicate token UUID occurrences are all
`invalidTarget`; unique tokens retain input order. Multi-target sending is intentionally not atomic
across devices and never retargets by route.

The manager keeps active issued capabilities for at most the 16 active sessions. On terminal it
moves the exact capability to a separate connection-keyed terminal cache capped at 64 entries and
30 seconds. Retention is `elapsed < 30 seconds`; equality expires. Capacity eviction uses oldest
terminal monotonic time then token UUID lexical order. A reconnect on the same route receives a new
capability and never deletes or satisfies the old exact cache entry. The terminal cache is unrelated
to the route-keyed recent-device presentation, clears on manager shutdown/full identity reset, and
is not restored across runtimes.

The manager alone classifies results on its serial executor. Malformed/duplicate/wrong-runtime/
wrong-generation, never-issued, expired, capacity-evicted, or reset-cleared tokens are
`invalidTarget`. If terminal transition wins before exact capability lookup, lookup finds the
terminal cache and returns `noLongerConnected`. If lookup first resolves the exact owned session but
that session is negotiating/disconnecting or terminal wins before its synchronous active-state
check, the result is `notActive`.
`queueRejected` means the exact session remained active but negotiated size or bounded queue
admission rejected the prepared draft. `queued` means that exact active queue buffered it. If
enqueue commits first, `queued` remains truthful even if terminal clears it immediately afterward.
The manager returns one typed, content-free result per requested target. The result panel contains at
most 16 rows and is replaced by the next attempt. `Queued locally` is the strongest success
wording. The UI never says delivered, received, acknowledged, executed, or processed. Actual
mailbox admission later creates the ordinary downlink journal Event; no independent sent history,
template, favorite, or retry store exists.

Composer fields, issued capabilities, terminal-cache entries, and results are memory-only and clear
at runtime shutdown. Event type/content, keep-latest key, target identifiers, and validation details
do not enter `UserDefaults`, logs, analytics, or recent rows. Standard user-invoked paste/copy/cut
remains available only inside operator-owned editable composer/filter/metadata controls; paste is
subject to the same pre-storage caps, and NearWire performs no background pasteboard read,
monitoring, restoration, or custom clipboard history. Received/stored Event inspector content has
no copy, cut, drag, share, or clipboard-export command.

### 10. MainActor, accessibility, and lifecycle work remain bounded

Every background completion carries runtime and presentation/attempt generation and is ignored
after replacement or shutdown. Each controller operation has one lock-protected
cancellation/delivery gate plus an exact work-tracker identity. Renderer and composer requests also
use per-request gates, but claimed values converge into one owner-level latest-only delivery pump.
That pump retains at most one value being handled plus one replaceable pending value and schedules at
most one MainActor drain successor; displaced content is released outside its lock. Cancellation
before delivery claim creates no MainActor task. Cleanup cancels and joins both the bounded
preparation worker and the one delivery pump, including a drain that already claimed ownership.
Destination selection uses the same finite ownership rule. Latest-only coalescers deliver changes at
the fixed cadence; no Event creates an unbounded MainActor chain. One
`ViewerExplorerCleanupReceipt` closes new control
and content admission, invalidates generations/subscriptions, cancels and joins catalog, timeline,
gap, causality, detail, live-match, raw/tree/renderer, export, and composer preparation, then clears
every resident recording/Event selection, canonical detail buffer, raw/tree/log/table/numeric
derived value, renderer selection, search/path/comparison/composer input, validation failure
containing user text, focused accessibility value, coalescer, and live value before releasing exact
originating leases. Persisted recording metadata remains store-owned and is not erased by runtime
cleanup. It then joins the existing session/store receipt; already queued downlink items remain
owned by session shutdown. Store runtime end is single-owner and idempotent: concurrent callers join
the owner, which deactivates and joins the coalesced status snapshot worker before closing SQLite.

Every new content-bearing scope/filter/input/prepared/detail/renderer model has redacted
`description`, `debugDescription`, and `customMirror`, including values whose operation was
cancelled. Their content is absent from logs, analytics, preferences, recent rows, and restoration
state. Only the explicit operator-editing clipboard boundary above applies.

Rows expose type, direction, priority, receive time, device alias, disposition, and transient/gap
state through combined accessibility labels. Search fields, filter controls, pause/resume, source
selection, renderer tabs, recording actions, disclosure, target selection, and send controls are
keyboard reachable. Status does not rely on color alone. Event content may appear in the selected
inspector accessibility tree because that is the explicit content surface; safe status and device
rows remain content-free.

### 11. Schema, query work, and resident presentation have explicit hard bounds

The store migrates schema 1 to schema 2 in one writer transaction by adding only three explorer
indexes: scoped Event UUID lookup `(recordingID, deviceSessionID, eventUUID, rowID)`, all-device gap
order `(recordingID, lastViewerWallMs, rowID)`, and device-scoped gap order
`(recordingID, deviceSessionID, lastViewerWallMs, rowID)`. Recording catalog traversal uses the
`Recordings` integer primary key plus the existing `RecordingVersions(recordingID, revision)` and
`Tombstones(recordingID)` unique indexes. Device traversal uses the existing
`DeviceSessions(recordingID, connectionOrdinal)` and
`DeviceSessionVersions(deviceSessionID, revision)` unique indexes. No catalog index is added unless
those exact plans fail the pre-implementation plan gate, in which case the artifacts must be amended
and reviewed before source apply. No Event/content row is rewritten and failed migration leaves
schema 1 intact and unavailable rather than partially upgraded.

Schema-1 upgrade is a separate resource-governed operation, not an unbounded startup call. A
dedicated serial migration executor opens only the writer off the MainActor; query/export readers
remain closed. It owns one exact migration token. Normal connections keep memory-only temporary
storage, but this one pre-reader migration connection uses disk-backed SQLite temporary sorting
through the system default VFS and the process's existing sandbox/private temporary hierarchy, a
32-MiB page/cache target, no application row array, and one index statement at a time. NearWire does
not read, set, or mutate `sqlite3_temp_directory`, `temp_store_directory`, `SQLITE_TMPDIR`, `TMPDIR`,
or install a custom VFS.

The migration writer is never published as the normal pool writer. After commit or rollback, the
migration executor closes that connection and joins until every sorter descriptor is gone. Success
then opens a fresh writer through the normal hardening path with `temp_store=MEMORY` and an explicit
8-MiB cache target, re-probes schema version 2, features, index presence/plans, and writer settings,
and only then opens the two fresh 8-MiB/memory-temp readers and publishes store availability. A
failed post-open probe closes the fresh connections and leaves storage unavailable; no FILE-temp or
32-MiB migration setting can cross the connection boundary.

Before `BEGIN IMMEDIATE`, NearWire verifies that the process-provided temporary directory is an
existing current-user-owned mode-`0700` nonsymlink directory. Checked arithmetic then requires both
the database volume and that temporary volume (once if they are the same volume) to have available
physical capacity of at least `512 MiB + 6 * allocated(main database + WAL + SHM)`; overflow,
unsafe temporary root, or insufficient space returns the safe `Migration needs more disk space`
state without beginning the transaction. SQLite-created sorter files may contain only the three
index key sets, never Event content JSON. The system VFS owns their delete-on-close lifecycle; the
migration receipt requires zero remaining process file descriptor for a sorter after success,
cancellation, or rollback. A progress handler
runs at most every 10,000 SQLite VM instructions, checks the exact token and a 256-MiB remaining-
space floor, and aborts before continuing when either fails. The migration fixture release gate is
at most 128 MiB process-heap growth above the idle writer baseline; configured cache/temp ownership
and retained-buffer counts are the deterministic gates, while total elapsed duration is diagnostic
because it scales with valid history size. Cancellation acknowledgement while SQLite is executing
must occur within 250 ms in the injected-progress fixture; rollback/cleanup is then joined before
the receipt completes.

Safe status is one of `Preparing history update`, `Updating history index 1/3` through `3/3`,
`Validating history update`, `Migration needs more disk space`, `Migration cancelled`, or
`Migration failed`; it contains no path, SQL, counts, or content. Networking and the bounded live
projection may operate while persistence/query/export remain unavailable. Viewer attempts the
migration automatically at most once per process. Cancellation, space block, or failure never spins;
only explicit Retry Storage or a later process launch may start a new generation.

All three index builds, final schema/feature probes, accepted `EXPLAIN QUERY PLAN` checks, and
`user_version=2` occur inside the one transaction before commit. Cancellation, termination,
resource failure, injected index failure, or a failed plan/probe rolls back to probe-valid schema 1;
schema 2 is published only after commit. Crash recovery likewise observes SQLite's intact schema-1
transaction boundary before any retry; OS temporary-file reclamation remains an operating-system
contract and is not mislabeled as secure deletion.

An all-device gap page uses the all-device gap-order index. A page scoped to 1 through 16 explicit
devices uses at most 16 device index ranges plus the recording-level `deviceSessionID IS NULL` range
and performs a bounded 17-lane merge for at most 32 results. Latest-revision checks use the existing
`GapVersions(recordingID, deviceSessionID, sequence, namespace, revision)` unique index under the
same frozen gap upper row ID. Accepted plans may not introduce a full scan, unbounded sort, or temp
B-tree proportional to recording size.

Recording/device catalog, gap, and causality operations each use at most 2,000,000 SQLite VM steps
and 250 ms, short transactions, exact operation-token cancellation, and `EXPLAIN QUERY PLAN` gates
against unbounded scan/sort/temp B-trees. Gap pages hold at most 32; causality reads at most nine
candidate rows. Live evaluation scans at most 512 entries/32 MiB, performs at most 16,384 predicate
checks and 1,000,000 JSON node visits, has a 100-ms deadline, and checks cancellation between
entries/predicates/path components. Budget exhaustion returns one fixed refine result and publishes
no partial match as complete.

Resident model caps are independent of page size: 200 recording rows, 200 device rows, 600 Event
rows, 128 gap markers, two boundary cursors per list plus one reload anchor, 16 selected-device
identities, one selected Event identity/detail buffer, and the renderer bounds above. Forward load
evicts from the backward edge; backward load evicts from the forward edge while preserving the
opposite reload cursor. An evicted selected row keeps only its content-free exact identity and one
detail buffer; it is reloaded on demand or selection clears if no longer visible. An evicted scroll
anchor moves to the retained boundary with an `Earlier/Later rows unloaded` marker and never
selects an unrelated row. Catalog selected recording/device identities use the same rule.

### 12. Durable and transient filters have an explicit compatibility contract

The normalized journal observation supplies identical metadata, receive timestamps, initial and
later disposition, and session scope to live and durable paths. Device/App/Bundle/type/direction/
priority/time, JSON path/scalar/containment, gap/drop, and terminal predicates have differential
tests against SQLite. Runtime- or device-scoped presence semantics are those defined in the live
projection and the equivalent frozen SQL snapshot.

FTS5 full-text tokenization remains an indexed durable-store operation. A transient `Not recorded`
row is not evaluated for `.fullText`; it does not match and the UI shows `Full-text search requires
recorded data — transient rows excluded.` This is an explicit outage limitation, not a guessed
Swift reimplementation of `unicode61`. Once the exact row becomes durable it participates normally.
No unavailable predicate state is treated as a match.

### 13. Release evidence separates deterministic gates from diagnostics

Every normative count, byte, deadline, generation, operation-token, VM-step, page, cursor, wake, and
lease limit is a release-blocking assertion. SQLite deadline tests use an injected monotonic clock
plus progress counters; renderer/live deadlines use injected clocks and cancellation checkpoints.
The migration resource fixture contains 100,000 Events and 10,000 gap revisions and must satisfy the
32-MiB cache configuration, at most 128-MiB measured heap growth, checked disk reservation, 250-ms
in-SQLite cancellation acknowledgement, exact rollback/probe, and zero surviving temp artifacts.

Live evidence offers 100,000 observations into a full ingress/window and must preserve the exact
64/20-MiB and 512/32-MiB ownership caps, one drain plus one dirty successor, at most one wake per
run-loop turn and ten per second, and zero callback-side encoding/traversal/eviction/large release.
Wall-clock callback latency and whole-process heap high-water are recorded as diagnostic machine
context only; the constant operation counts, ownership caps, and forbidden callback actions are the
portable release gates. Operator documentation may not present diagnostic timing or deterministic
accounted bytes as an actual-device latency or heap guarantee.

Catalog/gap/causality fixtures save accepted plans and assert the 2,000,000-step/250-ms logical
deadline, short transaction, result, and resident caps. Renderer fixtures assert every input,
derived-byte, row/node/preview/accessibility, and 100-ms logical deadline independently. Composer
fixtures assert editor storage formulas and exactly one encode/content traversal/copy before target
admission. Any missing counter, exceeded threshold, unexpected skip, or diagnostic presented as a
guarantee fails the change gate.

## Risks / Trade-offs

- **Transient/durable merge could duplicate rows:** use the exact journal identity, never Event
  UUID, and cover delayed durability, recovery, reconnect, and sequence reuse with tests.
- **Large JSON can stall the UI:** parse/format off-main, retain the existing content limits, bound
  visible tree nodes, and make renderer output page-bounded.
- **A broad filter can exhaust query work:** preserve existing VM/time gates and show a fixed
  refine-query state rather than silently widening or running an unbounded fallback.
- **Merged devices can obscure causality:** scope causality to exact device sessions, display aliases
  on every row, and surface missing/ambiguous links explicitly.
- **Pause can be mistaken for stopped capture:** keep a persistent `Presentation paused — capture
  continues` label and separate Pause from Pause New Devices and directional zero-rate controls.
- **Queue admission can be mistaken for delivery:** use typed local results and reserve durable
  history for actual mailbox admission.

## Validation Strategy

- Unit-test catalog cursors, selection bounds, live-window count/byte eviction, exact-key durable
  reconciliation, gap coalescing, renderer matching/fallback, JSON bounds, causality ambiguity,
  filter conversion, pause generations, scroll/tail state, and composer validation/result wording.
- Integration-test current unavailable runtime, recovery to a durable recording, single/merged
  timelines, new Events during paging/pause, storage failure, reconnect sequence reuse, delete
  revision races, pin/cleanup, filtered/complete export, and multi-target downlink admission.
- Exercise maximum legal Events, 16 devices, large histories, rapid filter/source replacement,
  cancellation races, renderer failures, and shutdown while query/export/composer work is active.
- Build and test the Viewer and affected package suites; validate accessibility presentation,
  content-free reflection/logging, privacy/package/project boundaries, and strict OpenSpec state.
- Save exact results, obtain independent architecture/API, correctness/testing, and
  security/performance/documentation reviews, remediate every actionable finding, and repeat until
  a fresh round reports zero unresolved findings.
