## MODIFIED Requirements

### Requirement: Timeline pages use bounded Viewer receive order and explicit diagnostics

Persisted Events SHALL use the store's stable `(viewerMonotonicNanoseconds, eventRowID)` order for single-device and merged timelines. Phone-created wall and monotonic times SHALL remain metadata only; the Viewer SHALL display them without using them to reorder different phones. Timeline pages SHALL contain 1 through 200 rows, default 100, use keyset traversal and virtualized presentation, and SHALL NOT construct the complete result set. The presentation model SHALL retain at most 600 Event rows, 200 recording rows, 200 device rows, 128 gap markers, two boundary cursors plus one reload anchor per list, 16 selected-device identities, and one selected Event identity/detail. Bidirectional eviction SHALL preserve the opposite reload cursor and SHALL clear or exactly reload an evicted selection rather than selecting an unrelated row.

Event pagination and gap pagination SHALL each own at most one in-flight page request. Repeated boundary-row appearance while that lane is active SHALL be coalesced without cancelling the admitted request or resubmitting its predecessor cursor. Once the request completes, a later trigger MAY use the installed successor cursor. A genuine failure from the admitted request SHALL remain visible.

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

## ADDED Requirements

### Requirement: Ordinary refresh preserves a stable bounded presentation

The cadence-driven refresh of an unchanged active scope and filter SHALL retain the current bounded Event, gap, selection, and scroll presentation while it releases predecessor traversal and loads successor data. Successor durable and live lanes SHALL replace their corresponding lanes atomically. If a successor input has no durable query or no live request, Viewer SHALL explicitly replace that absent lane with an empty lane. Scope, filter, materialization, Store, Pause/Resume, and Jump-to-Latest transitions MAY still clear or replace presentation according to their existing generation rules.

Loading or failure guidance MAY update without removing retained rows. A selected identity SHALL remain selected only while the exact identity remains resident after lane replacement. Ordinary refresh SHALL NOT briefly publish an empty list solely because predecessor traversal was released.

If ordinary refresh advances the presentation generation while the selected durable detail is still loading, Viewer SHALL cancel that stale detail authority and reload the exact selected identity only after a successor lane confirms it remains resident. If successor replacement removes or changes the selected identity, Viewer SHALL cancel detail, causality, and renderer work and clear every inspector content buffer before publishing the selection change. A ready inspector for the exact still-resident identity MAY remain visible across refresh.

If ordinary refresh fails before any lane replaces the retained presentation, Viewer SHALL restore reload authority for an exact still-resident selection. If one successor lane removes the selected identity before another lane fails, Viewer SHALL clear the now-nonresident selection and detail instead of restoring stale inspector content.

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

### Requirement: The filter editor has a bounded native macOS layout

The Event Explorer filter editor SHALL present every existing filter dimension in a vertically scrollable native macOS sheet with explicit grouped sections, stable labels, bounded control widths, and reachable Apply, Clear, and Cancel actions. It SHALL preserve existing draft validation, focus, and commit behavior. Layout SHALL remain usable at the declared minimum sheet size and SHALL NOT depend on `Form` automatically aligning nested custom field stacks.

#### Scenario: Operator opens Filters at minimum sheet size

- **WHEN** the filter editor appears at its declared minimum width and height
- **THEN** fields, labels, validation guidance, and actions remain aligned and reachable by scrolling
- **AND** controls do not overlap, collapse, or escape their section
