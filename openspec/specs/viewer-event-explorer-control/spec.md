# viewer-event-explorer-control Specification

## Purpose
TBD - created by archiving change viewer-event-explorer-control. Update Purpose after archive.
## Requirements
### Requirement: Viewer presents one three-column Event Explorer with an explicit recording scope

The Viewer SHALL present one native single-window workspace containing a source/device column, an Event timeline column, an Event inspector column, and a Viewer-to-App composer below the timeline/inspector region. Pairing, pending approval, Pause New Devices, device nickname/rate/telemetry, storage, and identity controls SHALL remain reachable without duplicating protocol ownership.

Exactly one current or historical recording context SHALL be selected. A Viewer-internal source-neutral scope SHALL identify either the exact current runtime logical ID or one positive historical recording row ID and SHALL identify either All Devices or 1 through 16 exact device logical IDs. Current device logical IDs SHALL be connection IDs and durable catalogs SHALL expose the same `DeviceSessions.logicalID`. Within that context the operator MAY select one device, 2 through 16 explicit devices, or All Devices. All Devices SHALL compile without materializing every historical device as a query predicate. V1 SHALL NOT merge different recordings. A current runtime whose store row is unavailable SHALL remain selectable as `Live — not recording` and SHALL transition to its durable row only by matching logical runtime identity.

Source, query, detail, renderer, export, and composer errors SHALL be presentation-local and SHALL NOT disconnect, pause, or mutate an App session.

Each application runtime SHALL create exactly one injectable component bundle for one explicit runtime logical ID. The bundle SHALL expose the same admission handoff owner, typed session-control facade, manager generation, composite store/live journal, live observation facade, and explorer cleanup receipt. The process-lifetime store runtime SHALL remain outside the bundle. Application code SHALL NOT recover typed control by downcasting a handoff owner or combine components from different runtime bundles.

#### Scenario: Current runtime has no durable recording

- **WHEN** networking is active while the local store is unavailable
- **THEN** the current live context remains selectable and shows only bounded transient Events with a `Not recorded` label
- **AND** no synthetic recording ID or durable-history claim is presented

#### Scenario: Operator selects several devices

- **WHEN** 2 through 16 devices from one recording are selected
- **THEN** one merged timeline shows only those devices with an alias on every row
- **AND** no Event from another recording or unselected device appears

### Requirement: Timeline pages use bounded Viewer receive order and explicit diagnostics

Persisted Events SHALL use the store's stable `(viewerMonotonicNanoseconds, eventRowID)` order for single-device and merged timelines. Phone-created wall and monotonic times SHALL remain metadata only; the Viewer SHALL display them without using them to reorder different phones. Timeline pages SHALL contain 1 through 200 rows, default 100, use keyset traversal and virtualized presentation, and SHALL NOT construct the complete result set. The presentation model SHALL retain at most 600 Event rows, 200 recording rows, 200 device rows, 128 gap markers, two boundary cursors plus one reload anchor per list, 16 selected-device identities, and one selected Event identity/detail. Bidirectional eviction SHALL preserve the opposite reload cursor and SHALL clear or exactly reload an evicted selection rather than selecting an unrelated row.

Committed transient Events SHALL merge by exact runtime/device/direction/wire-sequence journal identity. Peer Event UUID SHALL NOT be used as the durable/transient key. A transient row SHALL disappear only when its exact durable row is visible. Viewer gaps SHALL use a separate diagnostic lane bound to the same recording/device filters, query lease, and frozen gap upper row ID. It SHALL page at most 32 latest-revision markers by `(lastViewerWallMilliseconds, gapRowID)`, use stable `(recordingID, optional deviceSessionID, namespace, sequence)` identity, and SHALL NOT insert wall-time markers into monotonic Event order. Overlapping identities remain distinct; revisions above the frozen bound wait for a fresh traversal. Drop presence SHALL remain an explicit filter or badge and SHALL NOT imply peer acknowledgement.

#### Scenario: Two phones have skewed clocks

- **WHEN** their App-created wall times conflict with Viewer receive order
- **THEN** the merged timeline follows Viewer monotonic receive order and stable row-ID ties
- **AND** both original App times remain visible in detail

#### Scenario: Persistence misses an interval

- **WHEN** a bounded store gap covers Events that cannot be reconstructed
- **THEN** the timeline shows one diagnostic interval instead of interpolating ordinary Events
- **AND** later durable Events remain in normal receive order

### Requirement: Live and historical search share one closed filter model

The Event Explorer SHALL expose device/App/Bundle scope, exact and prefix Event type, direction, priority, Viewer receive-time range, literal content/full-text terms, safe JSON path existence/scalar equality/string containment, and gap/drop/terminal-disposition presence. Different dimensions SHALL combine with AND and selected values within one dimension SHALL combine with OR. Input SHALL be validated into one closed source-neutral `ViewerExplorerScope` and `ViewerExplorerFilter` before SQLite or live matching begins. That value SHALL be authoritative for presentation/live evaluation and SHALL compile into the existing SQL-only `ViewerEventQuery` only when positive durable recording/device row IDs exist. It SHALL never invent row IDs or omit an explicitly selected logical device merely because storage is unavailable. Durable and transient evaluation SHALL share one normalized committed observation and one Viewer receive timestamp. Device/App/Bundle/type/direction/priority/time, JSON, gap/drop, and terminal predicates SHALL have differential SQLite/live tests. Runtime-level gaps apply to all transient Events in that runtime, device gaps and positive drops apply to the exact device, and terminal disposition applies to the exact Event. Missing projection data SHALL not match.

One immutable materialization snapshot SHALL map the exact current runtime logical ID and individually materialized connection IDs to positive durable row IDs. The live matcher SHALL retain the full logical selection. Durable compilation SHALL include only exact selected devices present in that snapshot and SHALL issue no durable Event query if none is mapped; All Devices SHALL use the mapped recording with no device predicate. A current-to-durable mapping change SHALL increment the presentation generation, preserve logical selection, replace the durable traversal atomically, and reconcile exact journal keys without admitting another runtime.

FTS5 full text SHALL remain durable/indexed. A transient `Not recorded` row SHALL not be evaluated for `.fullText`, SHALL not match it, and SHALL show fixed guidance that full-text search requires recorded data. The Viewer SHALL NOT guess `unicode61` semantics in Swift.

At most one replaceable query generation SHALL exist. One non-MainActor arbiter SHALL exclusively own and refresh the traversal lease; page, detail, gap, causality, and filtered-export scope creation SHALL serialize through it. Every reader operation SHALL have an enqueue-to-completion token whose cancellation can affect only that exact active token, never a queued/completed successor. Source or filter replacement SHALL release the exact originating lease once and discard late results. A broad query that reaches its work budget SHALL show fixed refine-query guidance and SHALL NOT widen, use raw FTS/SQL, fall back to offset, publish a partial result as complete, or request replay from an App. Clearing filters SHALL begin one bounded current-scope traversal.

#### Scenario: Filter changes while a page is loading

- **WHEN** the operator replaces a JSON predicate before the old page completes
- **THEN** only the new generation may update the timeline and the old lease is released
- **AND** the old result cannot flash, widen, or alter session state

#### Scenario: Current storage is unavailable

- **WHEN** a validated filter is applied to the current transient live window
- **THEN** every supported transient dimension uses the same AND/OR semantics off the MainActor within the live-window bounds
- **AND** FTS5 full text excludes transient rows with fixed recorded-data guidance, while no SQLite availability or App replay is required

### Requirement: Presentation Pause never pauses capture or creates backlog

Pause SHALL increment the presentation generation before freezing rendered rows, selection, and scroll anchor so any older page/detail/live/renderer completion is stale. It SHALL NOT pause network receive, App/Viewer flow control, queue expiration, store admission, SQLite, maintenance, the transient live window, or control-event sending. While paused the Viewer SHALL retain only one latest change token, one latest durable upper row ID, and bounded saturating transient-change/gap counts; it SHALL schedule no refresh query or MainActor task per Event.

Source/filter/Pause/Resume/Jump to Latest SHALL share one generation state machine. Resume SHALL ask the query arbiter to release the stale traversal exactly once, start one fresh traversal with current scope/filters, reconcile exact transient/durable keys, and restore only the same still-visible Event selection. Manual scrolling SHALL disable auto-follow without changing Pause. Jump to Latest SHALL create one bounded tail traversal. Latest-only refresh SHALL own at most one wake, run no more than once per main run-loop turn and 10 times per second, and issue at most one query/live refresh per cadence.

#### Scenario: Many Events arrive while presentation is paused

- **WHEN** the store and transient window change faster than the UI can render
- **THEN** networking and persistence continue within their existing bounds while rendered rows remain stable
- **AND** resume performs one fresh query and shows any durable or transient overflow gap

### Requirement: Event detail and renderer selection are bounded and fallback-safe

The inspector SHALL expose complete validated raw JSON through 64-KiB navigable chunks, a bounded expandable JSON tree, Event type/ID, direction, sequence, priority, schema version, TTL, resolved local disposition, device aliases, App-created wall and monotonic times, Viewer receive time, correlation ID, and reply-to ID. It SHALL retain at most one canonical Event buffer. Pretty output SHALL accept at most 1 MiB input, produce at most 2 MiB, and run at most 100 ms; larger content SHALL remain chunked raw. The tree SHALL share backing ranges, load at most 128 children per expansion, materialize at most 4,096 nodes and 2 MiB of derived text, limit node previews to 256 bytes and focused accessibility content to 512 bytes, and remain generation-cancellable.

An immutable Viewer-internal renderer registry SHALL provide Generic JSON, log line, key-value table, numeric-series, and timeline renderers. Pattern selection SHALL prefer the most specific registered pattern. `log.*` SHALL accept at most 1 MiB, read one string or scan at most 4,096 top-level entries/1 MiB/100 ms for one string message, derive at most 64 KiB in 4-KiB chunks, and expose at most 512 bytes for focused accessibility. `table.*` SHALL accept at most 1 MiB, scan at most 4,096 top-level entries/1 MiB/100 ms, page 64 scalar rows, retain at most 128 descriptors and 512 KiB derived text, limit key/value previews to 256/1,024 bytes and focused accessibility to 512 bytes, and report `hasMore` without retaining copied full values. Structured log/table labels SHALL visibly isolate content and escape C0/C1 controls and bidirectional-formatting scalars as code-point tokens; exact content remains available through bounded raw navigation. Incompatible shape, cancellation, byte/time/work exhaustion, or renderer failure SHALL fall back to fixed Generic/refine guidance without failing the query. The numeric renderer SHALL stream at most one Event detail at a time, scan at most 200 rows, 8 MiB, and 100 ms, and retain at most eight finite series and 200 scalar points with no full content page. V1 SHALL NOT load third-party renderer bundles or implement the performance dashboard through this registry.

Causality lookup SHALL remain within the selected traversal's recording, exact device session, lease, and frozen Event upper row ID. Candidate rows SHALL be ordered by durable row ID and read with limit nine to return at most eight plus `hasMore`. Breadth-first expansion SHALL visit reply-to before correlation edges, use durable row ID for visited/cycle identity, stop at 32 nodes, and show missing, ambiguous, truncated, and cyclic links explicitly. A repeated peer Event UUID SHALL never become a false cycle or arbitrary parent.

#### Scenario: A log-pattern Event contains an incompatible object

- **WHEN** the registered log renderer cannot accept the selected content shape
- **THEN** the inspector renders complete Generic JSON and fixed renderer guidance
- **AND** the Event, query traversal, and connection remain unchanged

#### Scenario: Reply ID has several matches

- **WHEN** a peer reused one Event UUID within the device session
- **THEN** the causality view labels the link ambiguous and shows at most eight bounded candidates
- **AND** it does not silently select one match

### Requirement: Recording management and export preserve revisions, leases, and disclosure

The explorer SHALL expose bounded recording rename, note, annotation, pin, and unpin operations using the store validators and writer ordering. Manual deletion SHALL remain unavailable for active or leased recordings and SHALL require one explicit confirmation token bound to the current recording and annotation revisions. A stale or expired token SHALL delete nothing and SHALL refresh presentation from authoritative state.

Export SHALL offer Complete Recording and Current Filtered Result. Before the native save panel opens, Viewer SHALL show the bounded disclosure that JSON is unencrypted, aliases are pseudonyms, Event/App content can identify people or secrets, output is outside Viewer quota/retention, and the chosen provider may sync or back up the file. Progress/cancel SHALL preserve the store's single finite lease and atomic destination contract. V1 SHALL NOT persist destinations or add import, CSV, `.nearwire`, or automatic export.

#### Scenario: Recording changes after delete confirmation

- **WHEN** a name, note, annotation, or pin revision changes before confirmation is used
- **THEN** manual deletion changes nothing and the UI reloads the authoritative revision

#### Scenario: Operator exports the current filter

- **WHEN** disclosure is accepted and a destination is selected
- **THEN** the query arbiter freezes the current query and snapshot bounds into an immutable export scope, and the dedicated export reader streams exactly that scope under its independent finite export lease
- **AND** cancellation before commit preserves any prior destination

### Requirement: Viewer-to-App control composition reports only local admission

The bottom composer SHALL accept 1 through 16 manager-issued opaque control-target capabilities, one user Event type, ordinary JSON content, priority, TTL milliseconds, and `.normal` or `.keepLatest`. Each memory-only capability SHALL carry a random token UUID, exact runtime logical ID, manager generation, and connection ID and SHALL NOT be reconstructible or persisted by the UI. Event type SHALL be capped at 128 UTF-8 bytes. Before parse, JSON SHALL be capped by checked arithmetic at `min(active maximumEncodedContentBytes, (min(active maximumEncodedModelBytes, 16,777,216) - 65,536) / 4)` so Core model expansion and the Viewer hard single-Event limit are reserved; smaller negotiated limits remain per-target queue decisions. TTL SHALL use a `UInt64`-backed numeric editor whose adapter accepts at most nine ASCII digits, no sign or whitespace, and `1...active maximumTTLMilliseconds`. Search/path/comparison/name/note/annotation editors SHALL use their authoritative byte/scalar caps through incremental edit accounting rather than full rescans per keystroke. One replaceable off-MainActor generation SHALL validate and encode the EventDraft exactly once into an immutable prepared draft with checked accounted bytes and policy. User-entered reserved `nearwire.*` types SHALL be rejected. Keep-latest SHALL use the canonical Event type as its queue-local key.

The manager/session boundary SHALL classify each unique target in input order without UI prechecks, route retargeting, retry, re-encoding, content traversal, or deep copy. Active issued capabilities SHALL be bounded by the 16 sessions. On terminal, the exact capability SHALL move to a separate connection-keyed terminal cache of at most 64 entries retained while elapsed monotonic time is less than 30 seconds; equality expires, and capacity eviction SHALL use oldest terminal time then token UUID lexical order. Same-route reconnect SHALL issue a new capability without removing or satisfying the old entry. Shutdown/full identity reset SHALL clear the cache, which SHALL remain separate from route-keyed recent-device rows. All duplicate occurrences and malformed/wrong-runtime/wrong-generation/never-issued/expired/capacity-evicted/reset-cleared capabilities are `invalidTarget`. On the manager's serial executor, terminal-before-capability-lookup SHALL find the exact cache entry and return `noLongerConnected`; lookup-before-terminal followed by a negotiating/disconnecting state or terminal-before-session-active-check SHALL return `notActive`; `queueRejected` requires exact active ownership with negotiated-size or queue rejection; and `queued` requires that exact queue to buffer the prepared draft. Terminal after committed enqueue SHALL not rewrite `queued`. Multi-target sending SHALL NOT claim atomicity. `Queued locally` SHALL be the strongest wording; the Viewer SHALL NOT say delivered, received, acknowledged, executed, or processed. Only later secure-mailbox admission SHALL create the normal durable downlink Event.

Composer fields and at most 16 latest result rows SHALL be memory-only. Standard user-invoked paste/copy/cut SHALL be available only inside operator-owned editable composer/filter/metadata controls; pasted replacements SHALL pass the same incremental caps before model storage. NearWire SHALL perform no background pasteboard read/monitoring, custom clipboard history, or restoration. Received/stored Event inspector content SHALL have no copy, cut, drag, share, or clipboard-export command. V1 SHALL NOT add templates, favorites, automatic retry, an independent sent history, or Event content in `UserDefaults`/logs/recent rows.

#### Scenario: One of several targets disconnects during send

- **WHEN** three targets are selected and one loses active ownership before admission
- **THEN** that target reports `noLongerConnected` or `notActive` while the others receive their independent results
- **AND** no cross-device rollback or delivery claim is made

#### Scenario: A control Event enters a session queue

- **WHEN** the existing bounded downlink queue accepts the validated draft
- **THEN** the composer reports `Queued locally`
- **AND** history remains unchanged until secure-mailbox admission is journaled

### Requirement: Explorer updates and accessibility are bounded and privacy-aware

Catalog, timeline, gap, causality, live-match, detail, raw/tree/renderer, export, composer preparation, admission, and result completions SHALL carry exact runtime and operation/presentation generations and late generations SHALL not update the MainActor or enqueue control work. Coordinator replacement SHALL invalidate the shared generation validity of every predecessor operation before publishing its successor, including a client callback that already claimed delivery. Release, query replacement, tail page, and gap stages SHALL preserve that exact Store token, and each successor stage SHALL require the same still-published generation rather than dynamically routing through a replacement. Every controller operation SHALL use an atomic cancellation/delivery handoff with one exact tracked identity. Renderer generations and composer attempts SHALL additionally converge claimed results into one owner-level latest-only MainActor delivery pump retaining at most one processing and one replaceable pending result and scheduling at most one successor drain; displaced values SHALL be released outside the pump lock. Cancellation before delivery claim SHALL create no MainActor result task, while claimed owner-level work SHALL remain tracked until the pump handles or discards it. Native export-destination selection SHALL have one controller-owned cancellation/delivery identity, weakly capture the controller, and make a delayed response after flow/runtime cancellation a no-op. Export execution SHALL retain its exact controller delivery identity after a cancellation request until the gateway reports the commit-boundary outcome. A pre-commit cancellation SHALL preserve the prior destination and terminate as cancelled; a successful atomic replacement SHALL publish completed while the controller remains live even if cancellation or Store replacement raced with delivery. This content-free exact terminal receipt SHALL be the only predecessor-delivery exception and SHALL issue no successor-generation request. Latest-only refresh delivery SHALL obey the fixed cadence. Runtime shutdown SHALL first close explorer/control admission and subscriptions, invalidate generations, then cancel and join every named content-bearing operation, including both preparation workers, result pumps, export-destination selection, and any terminal export receipt. Before completion it SHALL clear every resident selection, canonical Event detail, raw/tree/log/table/numeric derived value and renderer selection, search/path/comparison/composer input, validation failure containing user text, focused accessibility value, coalescer, and live value, then release exact originating leases. Every new content-bearing model SHALL provide redacted description/debug reflection and SHALL remain absent from logs, analytics, preferences, recent rows, and restoration state; only the explicit operator-editing clipboard boundary applies. Persisted recording metadata remains store-owned. One finite explorer cleanup receipt SHALL then join the existing session/store receipt; already queued downlink Events remain owned by session shutdown.

Timeline rows and controls SHALL be keyboard reachable and expose combined accessibility labels for type, device alias, direction, priority, Viewer receive time, disposition, and transient/gap state. Pause, disconnected, unavailable, loading, selected, and error state SHALL not rely on color alone. Event content MAY appear in the explicitly selected inspector and its accessibility tree, but received/stored content SHALL remain absent from safe status/device/recent rows, generic reflection, logs, analytics, preferences, and clipboard export.

#### Scenario: Old detail completes after selection changes

- **WHEN** Event B is selected before Event A detail or renderer preparation completes
- **THEN** only B's exact generation may update the inspector
- **AND** no content from A reaches B's accessibility or presentation state

#### Scenario: Renderer or composer preparation is replaced before result delivery

- **WHEN** a blocked preparation owner receives 100,000 renderer replacements or composer send supersessions
- **THEN** cancelled generations create no MainActor result task and retained preparation/delivery ownership remains constant-bounded
- **AND** if many content-bearing results claim while the MainActor is blocked, one processing plus one replaceable pending result is the maximum retained pump state and cleanup joins the final drain until every tracked identity reaches zero

#### Scenario: Native export destination responds after lifecycle cancellation

- **WHEN** the operator acknowledges export disclosure, the save panel response is delayed, and the Explorer runtime seals before that response
- **THEN** cleanup cancels and joins the owned destination-selection operation
- **AND** a later approved URL creates no MainActor mutation, export request, file, retained destination, or old-controller retention

#### Scenario: Store replacement races a traversal stage

- **WHEN** release, query replacement, tail page, or gap work from Store generation A completes after generation B is published
- **THEN** the A result is discarded and launches no successor operation on B
- **AND** if replacement wins between validating an A predecessor and submitting its successor, the synchronous rejection also changes no presentation
- **AND** only an explicit fresh traversal may acquire B and update presentation

#### Scenario: Export cancellation races the atomic commit boundary

- **WHEN** cancellation or Store replacement races one exact export execution
- **THEN** a pre-commit cancellation preserves the prior destination and reports cancelled or store-replaced
- **AND** a gateway success after atomic replacement reports completed while the controller remains live, without reading from or launching work on a successor Store generation
