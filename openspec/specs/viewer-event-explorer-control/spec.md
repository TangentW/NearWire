# viewer-event-explorer-control Specification

## Purpose
TBD - created by archiving change viewer-event-explorer-control. Update Purpose after archive.
## Requirements
### Requirement: Timeline pages use bounded Viewer receive order and explicit diagnostics

Persisted Events SHALL use the store's stable `(viewerMonotonicNanoseconds, eventRowID)` order for single-device and merged timelines. Phone-created wall and monotonic times SHALL remain metadata only; the Viewer SHALL display them without using them to reorder different phones. Timeline pages SHALL contain 1 through 200 rows, default 100, use keyset traversal and virtualized presentation, and SHALL NOT construct the complete result set. The presentation model SHALL retain at most 600 Event rows, 200 recording rows, 200 device rows, 128 gap markers, two boundary cursors plus one reload anchor per list, 16 selected-device identities, and one selected Event identity/detail. Bidirectional eviction SHALL preserve the opposite reload cursor and SHALL clear or exactly reload an evicted selection rather than selecting an unrelated row.

Event pagination and gap pagination SHALL each own at most one in-flight page request and SHALL submit only while the Event coordinator owns a ready Store traversal for the current presentation generation. A paused presentation SHALL NOT claim query ownership, including when pause began from a ready traversal, because generation change or in-flight operation failure can invalidate the Store traversal. A cursor carrying backward direction SHALL belong to the chronological leading edge and a cursor carrying forward direction SHALL belong to the chronological trailing edge, independent of the direction used to obtain the current page. Pagination SHALL submit the direction carried by that cursor. A current cursor SHALL remain valid when another successful operation refreshes the sliding idle deadline of the same query lease; it SHALL remain rejected for a different query fingerprint, snapshot, lease identity, direction, or a deadline later than the authoritative current lease. Retained predecessor rows MAY remain visible during ordinary refresh, but their boundary callbacks SHALL NOT submit a predecessor cursor while traversal release or successor loading is active. Repeated boundary-row appearance while a lane is active SHALL be coalesced without cancelling the admitted request or resubmitting its predecessor cursor. Once the request completes, a later trigger MAY use the installed successor cursor. A fresh presentation generation SHALL clear page failures owned by the predecessor cursor. A genuine failure from a request admitted under ready ownership SHALL remain visible and SHALL NOT disconnect an App session.

Committed transient Events SHALL merge by exact runtime/device/direction/wire-sequence journal identity. Peer Event UUID SHALL NOT become a durable key or duplicate authority. A transient row SHALL disappear when its exact durable row is visible. When durable device materialization temporarily lags, one durable row MAY bridge to one visible transient candidate only if Event UUID is unique in both candidate sets and their available immutable committed presentation fields agree; reconciliation SHALL use the candidate's existing journal identity and SHALL fail closed on ambiguity or mismatch. The bridge SHALL NOT classify duplicates, mutate Store state, infer acknowledgement, or retain an Event-UUID index beyond the bounded presentation generation. Viewer gaps SHALL use a separate diagnostic lane bound to the same recording/device filters, query lease, and frozen gap upper row ID. It SHALL page at most 32 latest-revision markers by `(lastViewerWallMilliseconds, gapRowID)`, use stable `(recordingID, optional deviceSessionID, namespace, sequence)` identity, and SHALL NOT insert wall-time markers into monotonic Event order. Overlapping identities remain distinct; revisions above the frozen bound wait for a fresh traversal. Drop presence SHALL remain an explicit filter or badge and SHALL NOT imply peer acknowledgement.

#### Scenario: Durable visibility precedes device materialization

- **WHEN** one durable row and one visible transient candidate have a unique Event UUID and matching committed presentation fields but the Store device row has not mapped to the live connection
- **THEN** Viewer publishes durable visibility through the transient candidate's existing journal key and renders one durable row
- **AND** no duplicate, delivery, or Store mutation claim is made

#### Scenario: Event UUID bridge is ambiguous

- **WHEN** more than one durable or transient candidate shares the Event UUID, or available invariant fields differ
- **THEN** Viewer does not reconcile through Event UUID
- **AND** existing bounded diagnostics remain visible instead of silently hiding a distinct Event

#### Scenario: Boundary row appears repeatedly during pagination

- **WHEN** SwiftUI reports the same Event or gap boundary row more than once before its admitted page request completes
- **THEN** Viewer submits exactly one page request for that lane and preserves its active query lease
- **AND** it does not surface a stale-cursor bounded-view warning from a redundant request

#### Scenario: Two phones have skewed clocks

- **WHEN** their App-created wall times conflict with Viewer receive order
- **THEN** the merged timeline follows Viewer monotonic receive order and stable row-ID ties
- **AND** both original App times remain visible in detail

#### Scenario: Persistence misses an interval

- **WHEN** a bounded store gap covers Events that cannot be reconstructed
- **THEN** the timeline shows one diagnostic interval instead of interpolating ordinary Events
- **AND** later durable Events remain in normal receive order

#### Scenario: Initial tail page is loaded backward

- **WHEN** the Store returns a backward page in chronological display order
- **THEN** the oldest row supplies the backward leading-edge continuation and the newest row supplies the forward trailing-edge reversal
- **AND** appearing at the leading row requests older data without a direction mismatch or overlapping page

#### Scenario: Boundary row appears during ordinary refresh

- **WHEN** a retained first or last row appears while the predecessor traversal is releasing or the successor is loading
- **THEN** no Event or gap page request is submitted with the retained cursor
- **AND** no invalid bounded-view warning is created by that suppressed callback

#### Scenario: Operator pauses during traversal release

- **WHEN** the operator pauses while the predecessor traversal is releasing
- **THEN** Viewer retains the paused presentation without claiming query ownership
- **AND** durable detail and pagination remain suppressed until resume establishes a fresh traversal

#### Scenario: Operator pauses with Store work in flight

- **WHEN** the operator pauses while durable detail, Event pagination, or gap pagination is active
- **THEN** the paused state does not claim that the Store traversal remains queryable
- **AND** later durable work remains suppressed even if cancellation or failure clears the traversal

#### Scenario: Performance reveals a durable Event without traversal ownership

- **WHEN** raw-Event resolution returns a durable identity while Events are paused, failed, releasing, or loading
- **THEN** Viewer retains the exact selection intent without submitting detail against an absent traversal
- **AND** it loads that durable detail only after a ready successor traversal still contains the exact identity

#### Scenario: Exact reveal is absent from the successor window

- **WHEN** a deferred exact reveal reaches successor readiness but that Event is no longer resident
- **THEN** Viewer clears the pending reveal and inspector selection without submitting Store detail
- **AND** it does not restore the nonresident identity

#### Scenario: Store replacement invalidates an exact reveal

- **WHEN** Store rematerialization begins while a durable exact reveal is pending
- **THEN** Viewer clears the pending reveal and advances selection intent authority before installing replacement catalogs
- **AND** a numerically reused Event row ID in the replacement Store cannot expose unrelated content

#### Scenario: Boundary row appears after successor readiness

- **WHEN** the successor traversal is ready and a current boundary cursor exists
- **THEN** one bounded page request MAY be submitted for that lane
- **AND** repeated callbacks remain single-flight

#### Scenario: Sibling query refreshes the same traversal lease

- **GIVEN** a current Event or gap cursor was issued by the active bounded traversal
- **WHEN** a gap, Event detail, causality, or other successful operation advances that traversal's sliding lease deadline
- **THEN** the issued cursor remains usable against the same query fingerprint, immutable snapshot, and lease identity
- **AND** a cursor carrying a future deadline or foreign lease identity remains rejected

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

### Requirement: Ordinary refresh preserves a stable bounded presentation

The cadence-driven refresh of an unchanged active scope and filter SHALL retain the current bounded Event, gap, selection, and scroll presentation while it releases predecessor traversal and loads successor data. Successor durable and live lanes SHALL replace their corresponding lanes atomically. If a successor input has no durable query or no live request, Viewer SHALL explicitly replace that absent lane with an empty lane. Scope, filter, materialization, Store, Pause/Resume, and Jump-to-Latest transitions MAY still clear or replace presentation according to their existing generation rules.

Loading or failure guidance MAY update without removing retained rows. A selected identity SHALL remain selected only while the exact identity remains resident after lane replacement. Ordinary refresh SHALL NOT briefly publish an empty list solely because predecessor traversal was released.

Store-dependent pagination and detail work SHALL be admitted only when the coordinator owns a ready traversal. A durable Event selected while release or loading is active SHALL remain selected in a loading state and SHALL load exactly that identity after successor readiness confirms the identity is resident. A transient Event MAY load from the current live projection without Store traversal ownership.

If ordinary refresh advances the presentation generation while the selected durable detail is still loading, Viewer SHALL cancel that stale detail authority and reload the exact selected identity only after a successor lane confirms it remains resident. If successor replacement removes or changes the selected identity, Viewer SHALL cancel detail, causality, and renderer work and clear every inspector content buffer before publishing the selection change. A ready inspector for the exact still-resident identity MAY remain visible across refresh.

If ordinary refresh fails before any lane replaces the retained presentation, Viewer SHALL restore reload authority for an exact still-resident selection. If one successor lane removes the selected identity before another lane fails, Viewer SHALL clear the now-nonresident selection and detail instead of restoring stale inspector content.

The SwiftUI Event-list selection bridge SHALL NOT synchronously publish observable controller changes from within the active view-update transaction. Each deferred selection SHALL be bound to the presentation generation and a controller-owned latest-intent revision captured at scheduling time. Viewer SHALL apply it only if it remains the latest intent and its non-nil Event identity remains resident in that same generation. A direct selection or programmatic exact-Event reveal SHALL advance the same latest-intent revision so an older deferred list mutation cannot overwrite it.

#### Scenario: A new Event triggers live refresh

- **WHEN** a cadence refresh begins for the unchanged active Event scope
- **THEN** the existing rows remain visible until bounded successor lanes replace them
- **AND** the timeline does not flash through an empty presentation

#### Scenario: A successor lane is unavailable

- **WHEN** refresh compilation produces no durable query or no live request
- **THEN** Viewer atomically clears only that absent lane and preserves the other successor lane
- **AND** no stale row from the absent lane survives refresh completion

#### Scenario: Selected detail is loading during refresh

- **WHEN** ordinary refresh invalidates an in-flight detail request and a successor lane retains the exact selected Event
- **THEN** Viewer reloads that exact detail under the successor generation
- **AND** the inspector does not remain permanently loading

#### Scenario: Successor lanes remove the selected Event

- **WHEN** refresh completion no longer contains the selected Event identity
- **THEN** Viewer clears selection, detail, causality, renderer state, and canonical content together
- **AND** content from the removed Event is not left visible

#### Scenario: Refresh fails after partial lane replacement

- **WHEN** one successor lane removes the selected Event and another successor lane then fails
- **THEN** Viewer clears the nonresident selection and inspector detail while retaining the failed traversal guidance
- **AND** it does not restore content from the predecessor presentation

#### Scenario: Durable Event is selected during refresh

- **WHEN** the operator selects a retained durable Event while traversal release or successor loading is active
- **THEN** Viewer submits no detail operation against the absent or changing traversal
- **AND** after successor readiness retains the exact identity, Viewer loads that detail once under the successor generation

#### Scenario: SwiftUI commits Event selection

- **WHEN** macOS updates the Event `List` selection binding
- **THEN** observable controller mutation is deferred outside that view-update transaction
- **AND** the selected identity and inspector still converge on the clicked Event

#### Scenario: Deferred selection becomes stale

- **WHEN** the presentation generation changes, the Event is evicted, or a newer selection intent arrives before a deferred selection executes
- **THEN** Viewer ignores the stale deferred mutation
- **AND** it does not load or expose content outside the current bounded presentation

#### Scenario: Exact reveal supersedes a deferred list selection

- **WHEN** Performance-to-Event reveal selects an exact identity after an older list selection was deferred
- **THEN** Viewer preserves the exact reveal as the latest selection intent
- **AND** the older deferred list mutation cannot overwrite it on the next main-actor turn

### Requirement: The filter editor has a bounded native macOS layout

The Event Explorer filter editor SHALL present every existing filter dimension in a vertically scrollable native macOS sheet with explicit grouped sections, stable labels, bounded control widths, and reachable Apply, Clear, and Cancel actions. It SHALL preserve existing draft validation, focus, and commit behavior. Layout SHALL remain usable at the declared minimum sheet size and SHALL NOT depend on `Form` automatically aligning nested custom field stacks.

#### Scenario: Operator opens Filters at minimum sheet size

- **WHEN** the filter editor appears at its declared minimum width and height
- **THEN** fields, labels, validation guidance, and actions remain aligned and reachable by scrolling
- **AND** controls do not overlap, collapse, or escape their section

### Requirement: Viewer presents one current-Session Event workspace

The main Viewer window SHALL present one native current-Session Event workspace with a top Devices strip, a stable Event Timeline/Inspector region, and an optional bottom Viewer-to-App composer. It SHALL NOT expose a Sources sidebar, historical recording browser, Analysis mode picker, or embedded Performance dashboard. Events SHALL default to All Devices and MAY select up to 16 Device logical IDs. Device selection SHALL remain logical when durable storage is temporarily unavailable and SHALL rematerialize only exact current-Session identities.

The Devices strip SHALL expose bounded horizontally scrollable Device rows, All Devices, selected state, connection state, Device settings, and pending approvals without Event content. A Device row action SHALL update Event scope and the Device-details target without treating that row as a Source or mutating the independent Performance Device selection.

#### Scenario: Current runtime has no durable recording

- **WHEN** the working Store is unavailable but live committed Events exist
- **THEN** the current Session remains selected and bounded live rows remain filterable
- **AND** no historical Source or invented durable identity appears

#### Scenario: Operator selects several Event Devices

- **WHEN** the operator selects two current-Session Device logical IDs in the main window
- **THEN** Events show the merged bounded lanes for exactly those Devices
- **AND** an existing valid Performance Device selection remains unchanged

### Requirement: Current Session actions preserve one authoritative workspace

The Event Timeline toolbar SHALL expose Clear Events with a destructive confirmation. The top Session controls SHALL expose complete JSON Import and Export. Clear SHALL invoke the Store generation-safe operation and clear selected Event, inspector, gaps, and Performance presentation only after success. Import SHALL be disabled while any Device is active or pending and, after an atomic Store replacement, SHALL rematerialize Events, Devices, and Performance under one successor generation. Export SHALL freeze the complete current Session and retain the unencrypted disclosure.

No action SHALL create a second Source, recording-history row, or hidden Session. Stale pre-action page, detail, renderer, chart, or selection completion SHALL not update the successor presentation. Clear and import errors SHALL use fixed safe guidance without imported or Event content.

#### Scenario: Operator confirms Clear

- **WHEN** the current Session contains Events and the operator confirms Clear
- **THEN** Timeline, Inspector, diagnostics, and Performance reset after the Store commits
- **AND** connected Devices and later Events remain active in the same working Session

#### Scenario: Operator cancels Clear

- **WHEN** the destructive confirmation is dismissed
- **THEN** the Store, selection, Timeline, Inspector, and Performance remain unchanged

#### Scenario: Import replaces an inactive Session

- **WHEN** no Device is active or pending and a complete supported export commits
- **THEN** exactly one successor current Session presentation is materialized
- **AND** no predecessor row or transport capability survives as imported state

### Requirement: Workspace panels are independently visible and stable

The top Viewer header SHALL provide a labeled Performance-window button followed by independent Timeline, Inspector, and Composer visibility buttons. Each SHALL expose icon, selected state where applicable, tooltip, accessibility label/value, keyboard focus, and enabled state without relying only on color. Performance SHALL open or focus exactly one auxiliary window. Timeline, Inspector, and Composer buttons SHALL remain enabled whenever the main workspace is ready because Performance no longer replaces those regions.

The main Viewer SHALL render Timeline-only, Inspector-only, both through one stable native horizontal split, or a bounded empty explanation when neither is visible. Composer visibility SHALL add or remove the bottom region through one stable native vertical split. Hiding a panel or opening Performance SHALL NOT clear capture, filters, selection, Inspector state, composer draft, Event traversal, or Performance state. Panel preferences SHALL NOT persist beyond the process.

#### Scenario: Operator opens Performance and hides Inspector

- **WHEN** Performance is open and the operator toggles Inspector in the main window
- **THEN** both windows remain responsive and only the main Inspector region changes visibility
- **AND** Performance Device, range, pause, cards, and charts remain unchanged

#### Scenario: Raw reveal targets a hidden Inspector

- **WHEN** Performance resolves an exact raw Event while Inspector is hidden
- **THEN** the main window is focused or reopened and Inspector becomes visible for that exact Event
- **AND** the Performance window stays open

#### Scenario: Both Event panels are hidden

- **WHEN** Timeline and Inspector are both hidden
- **THEN** the main Event region presents compact guidance and top visibility controls remain reachable
- **AND** Event capture and both bounded traversal owners remain unaffected

### Requirement: SwiftUI publication is region scoped and animation safe

Main header, Devices, Timeline, Inspector, composer/layout, Performance window shell, and Performance dashboard SHALL use stable region identity and region-specific Equatable publication signatures. A source publication SHALL invalidate only regions whose visible signature changed. Timeline Event arrival SHALL NOT publish Inspector, composer/layout, or Performance-window shell changes when their visible values are unchanged. Performance refresh SHALL NOT reconstruct the main split container. Equivalent session snapshots SHALL be coalesced.

Data-only Timeline and Performance refresh SHALL preserve stable row/card/chart identities, scroll ownership, split positions, selection, and completed presentation and SHALL disable implicit insertion/removal/layout animation. UI refresh SHALL remain capped by existing bounded cadences and perform no Event-proportional work in either window root.

#### Scenario: High-frequency Events arrive with both windows open

- **WHEN** Events arrive faster than the UI cadence and selection/detail and Performance target do not change
- **THEN** Timeline publishes at most the bounded cadence while Inspector, main layout, and Performance-window shell publication counts do not increase
- **AND** rows, dividers, selected detail, cards, and charts do not flash through empty or animated intermediate states

#### Scenario: Performance refresh completes

- **WHEN** a new bounded Performance projection replaces the prior complete result
- **THEN** only dashboard presentation regions with changed semantic values update
- **AND** the main header, Devices strip, Timeline split, Inspector, and composer layout are not reconstructed

### Requirement: Events and Performance share one Session with coordinated traversal access

The Viewer SHALL expose Events and Performance over one authoritative Session without a second session manager, Store owner, query execution queue, Explorer controller, live projection, or raw Event cache. Event scope MAY contain up to 16 logical Devices; Performance SHALL own an independent exact logical Device selection. Runtime or Store replacement SHALL invalidate and join both presentation owners, clear predecessor content/cache/delivery state, and only then admit successor work even while either presentation is paused.

Store replacement SHALL synchronously clear predecessor Store-derived catalog rows and operation targets, revoke prepared delete/export and destination-selection authority, and deactivate both Store traversals. A Store-committed export SHALL retain its execution slot until authoritative completion. Explorer SHALL hold one rematerialization receipt until replacement change snapshot, first catalog pages, and bounded exact logical-ID lookup commit or a terminal Store failure commits an empty/failed catalog state. Catalog mismatch SHALL restart the bounded phase. Numeric row-ID reuse SHALL never preserve Event or Performance authority. Terminal failure SHALL retain logical selection only, compile no executable query/target, and SHALL NOT become Live, all Devices, or a nearby Device.

One coordinator and gateway generation SHALL retain at most one Event traversal and one Performance traversal. The generation's existing bounded operation queue and SQLite reader SHALL serialize all actual work. Event replace/end SHALL affect only Event traversal; Performance replace/end SHALL affect only Performance traversal. Discarded completion, refresh, range change, pause, reveal, or window close from one surface SHALL NOT end or retarget the other surface's traversal. Store replacement and shutdown SHALL cancel and join both.

Performance raw reveal SHALL pass only source generation and a metric-contributing journal key. The coordinator SHALL validate source, release only the Performance traversal while retaining the completed Performance presentation and its memory reservations, refresh the retained Event traversal snapshot, resolve exact durable or still-live identity through the serialized gateway, and ask the active Explorer to preflight and atomically perform its ordinary bounded reveal. Durable acceptance SHALL asynchronously load and validate the exact detail before mutating selection or Inspector; transient acceptance SHALL validate one live snapshot before mutation. A paused Event presentation SHALL retain its frozen Timeline rows and Pause state while a bounded snapshot-only replacement admits the exact detail request. Snapshot preparation and exact reveal acceptance SHALL return explicit success authority, and Main SHALL focus only after both authorities succeed and the coordinator revalidates its transition revision and target. Deleted, evicted, stale, unavailable, missing-detail, superseded, or finally rejected identity SHALL preserve the prior Event selection and Inspector, show fixed guidance in Performance without focusing Main, and SHALL not choose a nearby row. Superseding window, Device, range, Store, raw-request, or shutdown transitions SHALL cancel and join the pending exact-detail preflight. No JSON, metric, bucket, tooltip, availability text, or renderer object SHALL cross. Performance MAY resume exactly one fresh projection for the unchanged scope after reveal while the main Event presentation remains intact; if Performance is paused, it SHALL retain its completed presentation and defer that successor until Resume.

Presentation Pause SHALL freeze refresh only for an unchanged Performance Device/range. A paused range change clears crosshair/tooltip, records desired range, starts no traversal, and Resume starts one fresh projection. Reveal while paused is allowed only for the unchanged frozen scope. The dashboard SHALL remain separate from Renderer Registry; numeric and `chart.*` renderers SHALL not claim its multi-Event aggregation/current-card ownership.

#### Scenario: Performance opens while Events is active

- **WHEN** Event traversal and Inspector state are active and the operator opens Performance
- **THEN** Performance acquires only its bounded traversal through the shared serialized queue
- **AND** Event filtering, selection, paging, detail, and visible presentation remain active and intact

#### Scenario: Metric-specific raw Event is revealed

- **WHEN** a selected CPU accumulator resolves to a still-valid journal key
- **THEN** Performance releases only its traversal and Explorer opens exactly that Event in the main window
- **AND** Performance remains open and may resume without selecting a synthesized bucket or different contributor

#### Scenario: Performance Device changes while presentation is paused

- **WHEN** another exact Performance Device is selected while old charts are frozen
- **THEN** old Performance content and raw identities clear before successor admission
- **AND** the Event Device filter, Timeline, selection, and Inspector do not change

#### Scenario: Replacement Store reuses numeric row IDs

- **WHEN** a replacement Store assigns predecessor recording and device row IDs to different logical identities
- **THEN** Explorer clears predecessor catalogs before replacement I/O begins
- **AND** neither Event nor Performance admits successor work until exact replacement catalogs commit
- **AND** reused rows cannot become prior targets

#### Scenario: Selected Performance Device is absent from the replacement Store

- **WHEN** the selected Performance logical Device does not exist after rematerialization
- **THEN** bounded exact lookup completes before replacement admission
- **AND** Performance clears the invalid choice, applies the documented sole-Event or sole-available fallback when exact, and otherwise requests an explicit Device without changing Event scope

#### Scenario: Prepared operation crosses Store replacement

- **WHEN** delete confirmation, export disclosure, destination selection, or either traversal belongs to the predecessor Store
- **THEN** replacement revokes that authority before replacement rows are exposed
- **AND** an already Store-committed export retains its execution slot and publishes authoritative completion exactly once
