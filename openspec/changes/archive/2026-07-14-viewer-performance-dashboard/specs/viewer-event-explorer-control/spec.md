## ADDED Requirements

### Requirement: Events and Performance share source identity and one traversal owner

The single Viewer workspace SHALL expose Events and Performance over one authoritative source/device
selection without a second session manager, Store owner, query arbiter, Explorer controller, live
projection, or raw Event cache. Performance requires one exact current connection or historical
device session. Runtime/source/device replacement SHALL invalidate and join both presentation owners,
clear old content/cache/delivery state, and only then admit successor work even while Pause is active.
Store replacement SHALL synchronously clear predecessor Store-derived catalog rows and operation
targets, revoke prepared delete/export and destination-selection authority, and deactivate Event
traversal. A Store-committed export SHALL retain its execution slot until authoritative completion.
Explorer SHALL hold one rematerialization receipt until the replacement change snapshot, first
catalog pages, and bounded exact logical-ID lookups for the selected recording and up to 16 selected
devices have committed, or until a terminal Store failure has committed an empty/failed catalog
state. The first device page SHALL revalidate the recording page's frozen global catalog bounds in
the same read transaction that mints its device snapshot. Any mismatch SHALL report catalog change
and restart the entire bounded catalog phase. A Store-change signal during that phase SHALL remain
one dirty bit and start exactly one successor snapshot after the receipt completes. Events SHALL
remain inactive until the analysis coordinator joins that receipt. Numeric row-ID reuse alone SHALL
never preserve a selection or target across Store generations. A historical source absent by a
successful exact logical recording-ID lookup SHALL reset to Live. Terminal Store failure SHALL keep
the operator's historical source and explicit device selection, clear all partial catalog rows,
operation targets, and device mappings, and compile no successor query or performance target.
Unresolved historical authority SHALL remain non-executable across later filter, device, paging,
refresh, presentation, and management actions; numeric row-ID reuse SHALL NOT restore it or expose a
selected recording row. A source change during an active rematerialization receipt SHALL NOT strand
catalog work: selecting another historical source SHALL restart the bounded catalog phase for its
logical identity, while an explicit switch to Live SHALL cancel the active catalog phase, complete
the receipt and dirty-successor bookkeeping, and establish only a live scope with no durable Store
recording identity or device mapping. If ordinary refresh later presents a historical source while
authority remains unresolved, selecting it SHALL immediately clear the prior live scope and start a
new logical-ID rematerialization receipt owned by the analysis coordinator; the historical label
SHALL NOT retain or display live content. Events SHALL reactivate only after that joined receipt
commits, and Performance SHALL rebuild guidance or target only after the same barrier. Failure SHALL
NOT be reinterpreted as confirmed absence, Live, or all devices. A selected logical device absent
from the replacement catalog SHALL remain an explicit no-match selection that compiles no durable
query or performance target; it SHALL NOT collapse to the empty-selection meaning of all devices.

One analysis-mode coordinator SHALL serialize the query arbiter. Events-to-Performance SHALL cancel/
join active Explorer query/detail work and release the exact traversal before Performance submits.
Performance-to-Events SHALL cancel/join the active scan and release its traversal before Event query
or reveal. At most one mode SHALL own an active traversal; inactive immutable presentation/cache owns
no lease. Mode switch SHALL clear crosshair/tooltip and active work.

Performance raw reveal SHALL pass only source generation and a metric-contributing journal key. The
coordinator SHALL validate source, perform Performance-to-Events release ordering, switch mode, then
ask Explorer to resolve exact durable or still-live identity and perform its ordinary bounded reload.
Deleted, evicted, stale, or unavailable identity SHALL show fixed guidance and SHALL not choose a
nearby row. No JSON, metric, bucket, tooltip, availability text, or renderer object SHALL cross.

Presentation Pause SHALL freeze refresh only for an unchanged source/device/range. A paused range
change clears crosshair/tooltip, records desired range, starts no traversal, and Resume starts one
fresh projection. Reveal while paused is allowed only for the unchanged frozen scope. The dashboard
SHALL remain separate from Renderer Registry; numeric and `chart.*` renderers SHALL not claim its
multi-Event aggregation/current-card ownership.

#### Scenario: Events traversal is active when Performance opens

- **WHEN** the operator changes from Events to Performance
- **THEN** Explorer cancellation, join, and exact traversal release complete before Performance submits
- **AND** no old result or lease can retarget the shared arbiter

#### Scenario: Metric-specific raw Event is revealed

- **WHEN** a selected CPU accumulator resolves to a still-valid journal key
- **THEN** Performance releases its traversal, Viewer switches to Events, and Explorer opens exactly that Event
- **AND** no synthesized bucket or different metric contributor is selected

#### Scenario: Source changes while presentation is paused

- **WHEN** another device/source is selected while old charts are frozen
- **THEN** old Events/Performance content and raw identities clear immediately before successor admission
- **AND** Pause cannot show prior-device values under the new source

#### Scenario: Replacement Store reuses numeric row IDs

- **WHEN** a replacement Store assigns predecessor recording and device row IDs to different logical identities
- **THEN** Explorer clears the predecessor catalogs before replacement I/O begins
- **AND** the analysis coordinator admits no successor until exact replacement catalogs commit
- **AND** the reused rows cannot become the prior performance target

#### Scenario: Selected device is absent from the replacement Store

- **WHEN** the selected recording logical ID survives but a selected device logical ID does not
- **THEN** bounded exact lookup completes before the rematerialization receipt
- **AND** the missing selection remains explicit with no durable Event query or performance target
- **AND** Viewer does not reinterpret it as all devices

#### Scenario: Recording catalog changes before the first device page

- **WHEN** a recording mutation occurs after exact recording resolution and before device loading
- **THEN** the first device read rejects the predecessor recording snapshot as a catalog change
- **AND** Explorer restarts recording and device rematerialization from one new frozen generation

#### Scenario: Replacement Store lookup fails before identity is resolved

- **WHEN** a terminal Store failure prevents successful exact recording resolution
- **THEN** Explorer publishes empty or failed catalog state with no materialized Store identity
- **AND** the historical source and explicit device selection remain selected but compile no query or target
- **AND** later filter, paging, device, refresh, and management actions cannot restore numeric row-ID authority
- **AND** a deliberate switch to Live creates only a live scope until Store identity is resolved again
- **AND** Viewer does not switch the failed scope to Live or all devices

#### Scenario: Device phase fails after recording rows commit

- **WHEN** recording identity commits but the first device page or exact-device lookup fails terminally
- **THEN** Explorer clears the partial recording rows, device rows, operation targets, and device mapping
- **AND** it retains only the logical source/device selection in unresolved non-executable state

#### Scenario: Source changes while the device phase is pending

- **WHEN** the operator deliberately selects Live while a first-page or exact-device request is active
- **THEN** Explorer cancels the catalog request and completes the rematerialization receipt exactly once
- **AND** the analysis coordinator can finish its replacement transition without retained work
- **AND** the resulting scope has a live request but no durable query, recording ID, or device mapping

#### Scenario: Historical source is selected after live-only recovery

- **WHEN** a successor refresh presents historical rows after an explicit unresolved-to-Live switch
- **AND** the operator selects one of those historical logical identities
- **THEN** Explorer clears the live materialization and starts a fresh rematerialization receipt
- **AND** no live request or Event traversal remains authoritative under the historical label
- **AND** Events resumes historical traversal only after the receipt completes

#### Scenario: Ordinary actions follow terminal rematerialization failure

- **WHEN** paging or ordinary refresh later exposes the same logical row or a reused numeric row
- **THEN** selected recording presentation, operation targets, durable query, and performance target remain absent
- **AND** a recording management attempt is rejected without reaching the Store

#### Scenario: Prepared operation crosses Store replacement

- **WHEN** delete confirmation, export disclosure, or destination selection was prepared by the predecessor Store
- **THEN** replacement revokes that authority before replacement rows are exposed
- **AND** an already Store-committed export retains its execution slot across generation invalidation
- **AND** it publishes its deferred authoritative completion exactly once and retires all work
