## MODIFIED Requirements

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
