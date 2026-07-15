# viewer-performance-dashboard Specification

## Purpose
TBD - created by archiving change viewer-performance-dashboard. Update Purpose after archive.
## Requirements
### Requirement: Performance projection is a rebuildable bounded view of raw Events

The Performance dashboard SHALL be a rebuildable projection of raw `nearwire.performance.snapshot` Events in the one current working Session. It SHALL never become a second persistence source, recording, or history owner. Clear and Session import SHALL advance the shared Store/presentation generation, cancel predecessor scans and chart preparation, clear stale buckets/tooltips/raw locators, and rebuild only from successor current-Session Events.

Each accepted snapshot SHALL retain the existing Core decoding, availability, finite-value, time-basis, bounded range, and aggregation semantics. Imported device aliases remain offline pseudonyms and SHALL NOT be treated as connected control targets.

#### Scenario: Current Session is cleared

- **WHEN** a Performance scan or chart delivery belongs to the pre-Clear generation
- **THEN** it cannot update the cleared dashboard
- **AND** later current-Session snapshots rebuild the projection normally

#### Scenario: A complete Session is imported

- **WHEN** import atomically installs valid raw Performance Events under a successor generation
- **THEN** the dashboard rebuilds from those raw Events using normal bounded projection
- **AND** no imported Device is presented as an active transport target

### Requirement: One exact device scope freezes live before Store and uses deterministic ranges

Performance SHALL accept exactly one current connection or one historical device session. Zero,
all-device, or two-through-sixteen-device selection SHALL show
`Select one device to view performance` and start no traversal. V1 SHALL NOT stitch reconnects or
overlay devices.

Historical upper time SHALL be exact device end monotonic time, or frozen recording upper time for
an interrupted session; an empty session uses start for both bounds. Current freeze SHALL first ask
the live projection executor to drain bounded accepted ingress and return exact runtime/connection/
live generation, slice revision, anchor, candidates, and gaps. Store Event/gap uppers freeze after
that. Durable rows SHALL be limited at/before the live anchor and merged with the slice by journal
key. Events after live freeze are outside the scope; Events at/before it cannot disappear during a
durable-commit race.

Ranges SHALL be one, five, and fifteen minutes plus Current Session, default five minutes. Bounds are
inclusive `[lower, upper]`. Fixed lower SHALL be
`max(deviceStart, upper - (durationNanoseconds - 1))` using checked saturation; Current Session starts
at device start. Zero duration is one tick. Viewer monotonic receive time orders and buckets;
Viewer wall time labels; App sample time never reorders.

Checked span SHALL be `upper - lower + 1`, width `ceil(span / 512)`, count `ceil(span / width)`, and
index `(sampleTime - lower) / width`. Final upper belongs to the final bucket; an interior exact edge
belongs to the later bucket. Equal-time samples compare runtime UUID network-order bytes,
connection UUID network-order bytes, direction ordinal (`appToViewer=0`, `viewerToApp=1`), then
unsigned wire sequence.

#### Scenario: Live commit races current freeze

- **WHEN** a live sample commits durably between the live-first anchor and later Store-upper freeze
- **THEN** it contributes exactly once if at/before the anchor and not at all if after the anchor
- **AND** locator replacement cannot move it between buckets

#### Scenario: Several devices are selected

- **WHEN** two devices are selected in the shared source column
- **THEN** fixed one-device guidance appears with zero retained projection/query state
- **AND** the merged Event timeline remains unchanged

### Requirement: Long ranges use one globally bounded cache and aligned aggregation

The cache key SHALL contain source/device identity, range kind, lower/upper bounds, Store generation,
Event/gap upper rows, runtime/live generation, and live-slice revision. Only exact equality is a hit.
Successful hit or publication touches LRU. Atomic fifth insertion SHALL evict oldest touch then
canonical cache tuple: source-kind ordinal (`current=0`, `historical=1`), source UUID network-order
bytes or sign-bit-flipped big-endian positive row ID, device UUID bytes or row ID, range ordinal
(`one=0`, `five=1`, `fifteen=2`, `session=3`), lower, upper, Store generation, Event upper, gap upper,
runtime UUID bytes, live generation, then slice revision. UUID and integer comparisons SHALL use raw
bytes/unsigned values, never locale, description, hashing, or live/durable locator. Current-anchor
advancement makes a new key. Source/device replacement SHALL join old work and clear the entire
global cache before successor admission. Source generation SHALL remain publication and raw-reveal
authority rather than cache identity. An exact-key cache entry SHALL be reused only when every
retained representative is absent or matches the active source generation; otherwise the already-
owned incoming result SHALL atomically replace that entry before publication.

One result SHALL contain at most 512 buckets and ten numeric accumulators per bucket: estimated and
maximum FPS, CPU, memory, battery fraction, both byte rates, both queue depths, and dropped count.
Each accumulator SHALL retain finite min/max/sum/count, first/last Viewer times, counts for every
nonmeasurement state, a discontinuity flag, and one center-nearest contributing journal key. Distance
uses Viewer monotonic time; ties use earlier time then the canonical journal tuple above. Charts
SHALL show average and min/max envelope and disclose aggregation; no complete raw-sample array is
retained.

Per bucket, categorical battery/thermal/low-power state SHALL retain only first/latest/last plus a
saturating change count. One result SHALL retain at most 128 detailed gaps, 128 invalid diagnostics,
one saturating detail-loss count, and fixed summaries for all 16 V1 inventory keys including
unavailable-only GPU, power, and Celsius temperature. Six charts SHALL create at most 12,288 marks,
one tooltip SHALL exist, and each chart SHALL expose at most 64 accessible bucket summaries.

Each completed result SHALL be at most 8 MiB. Deterministic charges SHALL be: controller/source base
4,096; cache key 256; result base 4,096; bucket 2,048; detailed gap 256; invalid diagnostic 128;
availability entry 64; model wrapper 1,024; delivery wrapper 256; tooltip 2,048; crosshair 64; Event
carrier 512 plus copied content; normalized gap carrier 256. A result charge SHALL equal base + key +
buckets + detailed gaps + invalid diagnostics + 16 availability entries; an active reducer uses the
same formula at current counts. Presented/delivery wrappers SHALL reference an already charged
immutable result rather than charge its content twice; distinct pending results are charged
independently.

One shared ledger SHALL cap controller/source, active reduction, four completed entries, presented
model, pending/processing delivery, tooltip/crosshair, diagnostics, and identities at 16,777,216
deterministic bytes. One Store Event page SHALL be at most 4,460,544 bytes (4,096 wrapper + 512
carriers + 4,194,304 content). One live slice SHALL be at most 4,493,312 bytes (4,096 wrapper + 512
carriers + 4,194,304 content + 128 normalized gaps). One Store gap page SHALL be at most 8,704 bytes
(512 wrapper + 32 normalized gaps), and the decoder buffer SHALL be 65,536 bytes. All may coexist,
for an exact performance-owned peak of 25,805,312 deterministic bytes. This is not a Swift heap
guarantee. LRU eviction SHALL precede insertion; a still-oversized result SHALL fail with fixed
guidance and no partial chart.

#### Scenario: One hundred thousand samples alternate every state

- **WHEN** 100,000 samples alternate categorical values, missing metrics, invalid content, and gaps
- **THEN** retained buckets, transitions, diagnostics, marks, accessibility values, and bytes remain at their exact caps
- **AND** detail loss saturates without an Event-sized side list or reconnected line

#### Scenario: Fifth completed key is inserted

- **WHEN** four exact cache keys exist and a fifth result completes within all byte bounds
- **THEN** the deterministic least-recently-used entry is released before insertion
- **AND** no prior-source value survives a source/device replacement

### Requirement: Availability, cards, and gaps preserve uncertainty without interpolation

Present values, including numeric zero and categorical `.unknown`, SHALL be measured. Explicit
reasons SHALL display Unsupported, Disabled, Permission denied, or Temporarily unavailable. Absence
without a matching known record SHALL display Not collected. Invalid typed content SHALL display
Invalid snapshot.

Cards SHALL use the latest raw performance Event at/before the anchor, looking back at most 180
seconds even beyond chart lower bound. If none exists, every card SHALL show No recent sample and no
freshness deadline SHALL arm. Otherwise freshness SHALL be evaluated before typed state. A valid
positive header interval uses `min(180 seconds, max(3 * sampleInterval, 3 seconds))` with checked
arithmetic; an invalid or unreadable header uses three seconds. Equality is stale. No recent sample
SHALL win over Invalid, explicit unavailable, and Not collected. Only a fresh latest Event is decoded
for card state: invalid shows Invalid; a missing or unavailable metric shows that state without
falling back to an older Event. Range changes SHALL not change card identity.

Every current-source card result SHALL carry source generation, latest-Event journal key, absolute
Viewer-monotonic freshness deadline, and monotonically advancing deadline revision. The MainActor
delivery gate SHALL validate all values and an injected current-uptime clock at both claim and apply.
If `now >= deadline`, chart data MAY publish but every card SHALL be restated as No recent sample and
no deadline SHALL arm. A callback SHALL mutate only the same generation, Event identity, deadline,
and revision; scheduling SHALL occur only for `deadline > now`, fire at most once, and never re-arm an
elapsed deadline. While paused, expiry SHALL set one bounded dirty bit without mutating frozen
presentation; Resume starts one fresh projection. Source/runtime replacement SHALL invalidate the
receipt before joined cleanup.

Historical cards SHALL never compare persisted monotonic values with current uptime and SHALL never
schedule a freshness callback. They SHALL evaluate the same latest-Event horizon once against the
frozen historical upper in that recording's monotonic domain. Checked distance at or beyond the
horizon SHALL be No recent sample; otherwise the latest typed state is frozen. Pause SHALL not age a
historical card. Current/historical source switching SHALL invalidate and join the prior receipt
before evaluating the successor clock domain.

Buckets SHALL aggregate measured values while separately counting every nonmeasurement state. If no
measurement exists, display precedence SHALL be Invalid, Permission denied, Temporarily unavailable,
Disabled, Unsupported, then Not collected. Tooltip SHALL disclose both statistics and counts.

Frozen Store/live gaps SHALL be exact-device or recording-wide. Each gap SHALL cross the projection
boundary only as a fixed 256-byte normalized carrier containing row/scope identity, count, optional
wall interval, one kind from `eventLoss`, `storageContinuity`, `controlContinuity`,
`lifecycleContinuity`, `presentationLoss`, and `unknown`, and one applicability from `performance`,
`irrelevant`, and `uncertain`. Variable namespace, reason, and direction strings SHALL not cross.

Store kind mapping SHALL use case-sensitive ASCII exact/prefix comparison:
`missingInitialEvent.*` to eventLoss; `storageUnavailable`,
`midRuntimeRetry`, `liveStart`, and `store*` to storageContinuity; `uplinkDisposition*`,
`dropJournal*`, and `policyJournal*` to controlContinuity; `deviceClose*` and `shutdownStructural*` to
lifecycleContinuity; and `coalescedOverflow` or any unrecognized reason to unknown. Store direction
mapping SHALL be `appToViewer`/`both` to performance, `viewerToApp` to irrelevant, and `unknown` or
unrecognized to uncertain. Live ingress/window overflow SHALL be eventLoss, Store unavailable or
recovery storageContinuity, resident conflict presentationLoss, and diagnostic loss unknown; every
positive live counter SHALL be uncertain and interval-less.

Irrelevant gaps SHALL be counted without breaking performance series. The fixed Store gap-page
wrapper SHALL carry generic `hasMoreRows`, a saturating performance-or-uncertain total, and
`hasMoreApplicableGaps`. Store SHALL classify the complete frozen matching metadata scope under its
cancellation, VM, and injected-time budget before setting applicable overflow; classification budget
exhaustion SHALL return `hasMoreApplicableGaps` true regardless of the partial count and SHALL never
claim complete classification. Hidden irrelevant-only rows SHALL set only `hasMoreRows` and SHALL not
break a series. A hidden performance/uncertain row SHALL set `hasMoreApplicableGaps`.

Performance or uncertain schema-2 Store gaps SHALL map only when a valid wall interval overlaps one
unique monotonic bucket envelope. An interval-less applicable live gap, invalid interval, regression,
ambiguous/nonoverlap mapping, Store/live `hasMoreApplicableGaps`, or more than 128 combined applicable
details SHALL set Unplaced gap, saturate detail loss, and suppress every inter-bucket line segment
while retaining disconnected points/envelopes. The live-slice wrapper SHALL carry the same saturating
applicable count and applicable-overflow bit, retain at most 128 carriers, and set the bit whenever
applicable input/detail exceeds retained evidence. Unknown input SHALL be conservative; Viewer SHALL
not guess placement.

Adjacent samples SHALL split at
`min(180 seconds, max(3 * max(previousInterval, currentInterval), 3 seconds))`. Invalid snapshots
split all metrics. A missing/unavailable metric splits only that metric. Any break inside a bucket
prevents connection to both neighbors; overflow retains break flags and never reconnects a line.

#### Scenario: CPU is zero while GPU is unsupported

- **WHEN** CPU is measured as zero and GPU has an unsupported unavailable record
- **THEN** CPU card/chart show measured zero and the fixed availability section shows GPU Unsupported
- **AND** no numeric GPU value or Not collected replacement is shown

#### Scenario: A wall-time gap cannot map monotonically

- **WHEN** Viewer wall time regresses so a durable gap has no unique monotonic bucket
- **THEN** the dashboard labels Unplaced gap and suppresses every inter-bucket line for the range
- **AND** it neither migrates schema nor interpolates a guessed location

#### Scenario: A downlink-only gap is present

- **WHEN** a normalized Viewer-to-App-only gap overlaps an otherwise continuous performance range
- **THEN** the gap is counted as irrelevant and does not break an App-to-Viewer performance series
- **AND** an unknown direction under the same conditions is uncertain and suppresses conservatively

#### Scenario: Store pagination hides one applicable gap

- **WHEN** two receipts retain the same 128 irrelevant gaps but only one has a hidden applicable tail
- **THEN** both may report more rows while only the latter reports `hasMoreApplicableGaps`
- **AND** the irrelevant-only range remains connected while the hidden-applicable range is Unplaced

#### Scenario: Live gap evidence exceeds the retained cap

- **WHEN** the live freeze observes 129 applicable loss occurrences but retains at most 128 details
- **THEN** its saturating total and `hasMoreApplicableGaps` survive truncation and set Unplaced gap
- **AND** no overflow path reconnects a chart line

### Requirement: Projection work makes progress, stays fresh, and handles Store availability

The forward Store scan SHALL carry an opaque last-examined key independent of emitted rows. A turn
SHALL examine at most 4,096 candidate Events, emit at most 512 carriers, copy at most 4,194,304
content bytes, charge 512 bytes per carrier, execute at most 5,000,000 VM instructions, and stop at
50 ms on an injected monotonic clock. Matching and nonmatching rows advance. Byte exhaustion stops
before the next row; VM/time exhaustion after a row advances through it. Exhaustion before the first
candidate is terminal work-limit failure. Equality stops. Host elapsed time is diagnostic only.

One source generation SHALL own one running frozen scan and at most one dirty successor, one Store
traversal/lease, one bounded live slice, one latest-only MainActor pump, and one replaceable freshness
deadline. New refresh tokens SHALL not cancel running work; its still-current frozen result may
publish, followed by one successor using the latest token. The deadline is not a poll; equality marks
stale. Claim/apply SHALL revalidate its generation/Event/deadline/revision and injected clock; a late
current result cannot reverse stale to fresh or schedule a past deadline. Historical scope SHALL own
no deadline and use only its frozen same-domain upper. No task per sample or partial-complete chart is
allowed. Deadline cancellation MAY be cooperative. One deadline owner SHALL retain at most one
reschedulable physical worker and one logically active wake across arbitrary re-arming. Invalidation
SHALL disarm that worker, and cleanup SHALL cancel and wait that same worker before completing; no
per-arm cancelled-handle collection is allowed.

Source/device/runtime replacement SHALL immediately invalidate, cancel, join, clear cache/model/
delivery content, and only then admit successor work even while paused. Store status SHALL expose the
installed explorer-coordinator generation. Ordinary status publication within that generation SHALL
request a bounded refresh; a changed generation SHALL take the full replacement path before any new
projection. Store replacement SHALL first invalidate the Performance controller without automatic
rebuild and SHALL synchronously clear Explorer's predecessor Store-derived rows and targets. Explorer
SHALL revoke predecessor prepared operation authority and deactivate Event traversal. It SHALL expose
one rematerialization receipt that completes only after the replacement change snapshot, first
recording/device pages, and bounded exact logical-ID lookups for a selected recording or up to 16
selected devices outside those pages have committed. Catalog generation changes SHALL restart this
phase; terminal Store failure SHALL commit an empty/failed catalog state before the receipt completes;
and one dirty Store-change signal SHALL survive until one successor snapshot starts afterward. The
analysis coordinator SHALL join Event deactivation and that receipt with the prior mode transition,
controller cleanup, and raw resolver before reactivating Events, recompiling target/guidance, and
admitting exactly one successor. Reused numeric row IDs without matching logical identities SHALL
remain unselectable. A missing historical logical recording ID SHALL reset Explorer to Live. A
missing selected device logical ID SHALL remain an explicit no-match selection with no durable Event
query or performance target and SHALL NOT become all devices. A
paused range change clears crosshair/tooltip, records desired range, starts no query, and Resume
starts one fresh projection. For unchanged scope, Pause freezes presentation while capture/dirty
state continue bounded.

Historical Store unavailable SHALL show only Storage unavailable. Current Store unavailable MAY
publish a separately labeled Live window only projection from a fresh bounded slice with leading
unknown-history break and overflow disclosure; it SHALL not claim Complete Range. Failure during a
durable scan discards all partial reducer/cache state and releases traversal/lease. Current then
starts a fresh live-only generation; historical remains unavailable. Recovery starts one fresh
scope, or marks one dirty successor until Resume, and never merges predecessor partial work.

#### Scenario: Sustained refresh arrives during a blocked scan

- **WHEN** 100,000 refresh tokens arrive while one long scan is blocked
- **THEN** one running scan and one dirty successor are the maximum retained refresh work
- **AND** the running frozen result can complete before one latest successor starts

#### Scenario: Store coordinator is replaced

- **WHEN** Store status publishes a different installed coordinator generation during ready, paused,
  blocked-scan, or claimed-delivery state
- **THEN** the prior model, cache, raw action, deadline, and delivery authority clear immediately
- **AND** predecessor work joins before one new source generation can project from the replacement

#### Scenario: Store fails after a middle page

- **WHEN** historical projection has reduced several pages and Store becomes unavailable
- **THEN** every partial bucket and lease is discarded and only Storage unavailable publishes
- **AND** recovery starts a completely fresh frozen traversal

#### Scenario: A current claimed result crosses its freshness deadline

- **WHEN** a fresh result is claimed before its absolute deadline but reaches MainActor at or after it
- **THEN** chart data may publish while cards remain No recent sample and no elapsed deadline re-arms
- **AND** a prior callback or source generation cannot reverse the stale state

#### Scenario: Historical analysis follows an uptime reset

- **WHEN** a historical recording's frozen monotonic upper is greater than the current process uptime
- **THEN** cards evaluate only against that historical upper and schedule no freshness callback
- **AND** switching back to current invalidates the historical receipt before using current uptime

### Requirement: Performance UI is accessible, privacy-aware, and fully cleared

The native singleton macOS Performance window SHALL use an accessible exact-Device picker, scalable current cards, a fixed 16-key availability section, six bounded system Charts views, fixed ranges, one synchronized pointer/keyboard crosshair, aggregate tooltip, representative raw action, Show Viewer action, and deterministic English runtime/device/empty/loading/live-only/unavailable/error guidance. State SHALL not rely on color. Accessibility SHALL combine metric, unit, Viewer time, statistics, discontinuity, and availability within the 64-summary-per-chart cap.

The Performance Device selection SHALL be independent of the main Event multi-selection. On first open or after invalidation it SHALL prefer an exact sole Event selection when still available, otherwise the sole available Device, otherwise explicit no selection. A valid existing choice and range SHALL remain in process memory across Performance-window close/reopen and SHALL not persist across process launch. Changing the Performance Device SHALL clear predecessor content and work without changing Event scope or Inspector state.

Received values SHALL have no copy, cut, drag, share, clipboard-export, preference, restoration, recent-row, safe-status-row, log, analytics, or content-bearing reflection sink. Closing Performance SHALL cancel/join active projection/reveal/deadline work, release Performance traversal, and clear received metric values, buckets, tooltip, accessibility values, cache, locators, and delivery state without altering Event presentation. Runtime end, listener failure, TLS/full reset, Store replacement, deinitialization, and claimed-delivery cleanup SHALL additionally clear all coordinator selection/content state before the existing receipt completes. Unsealed controller deinitialization SHALL synchronously seal any externally retained model and transfer cancellation/join receipts and required owners to a detached cleanup owner until all work and charged memory reach zero.

#### Scenario: Performance opens with several Devices and no exact suggestion

- **WHEN** several Devices exist and Event scope is All Devices or multi-selected
- **THEN** the Performance window presents Choose a Device and starts no projection traversal
- **AND** choosing one Device does not change Event scope

#### Scenario: Performance window closes and reopens

- **WHEN** the operator closes Performance and later reopens it during the same runtime
- **THEN** prior received metric content and active work are absent while the valid Device and range controls are restored
- **AND** one fresh bounded projection starts without disturbing Event state

#### Scenario: Claimed chart delivery races cleanup

- **WHEN** cleanup begins after a chart result claimed MainActor delivery
- **THEN** cleanup waits until that exact result is discarded and every received Performance value is cleared
- **AND** Event traversal, selection, and Inspector remain authoritative unless the whole runtime is ending

### Requirement: Events and Performance reveal metric-specific raw identity through coordinated traversals

Every measured accumulator SHALL carry a contributing journal key and source generation. Live-to-durable reconciliation SHALL update only its locator. Open Raw Event SHALL resolve the selected metric's key at action time, preferring exact durable then still-live. Deleted, evicted, stale, or unresolvable keys SHALL show fixed guidance and SHALL not choose a neighbor. No JSON, metric, bucket, tooltip, or renderer object SHALL cross controllers; derived buckets SHALL not export.

One coordinator SHALL serialize lifecycle transitions while the shared Store gateway retains one bounded Event traversal and one bounded Performance traversal under one serialized operation queue. Opening Performance SHALL NOT invalidate Event query/detail work, clear Inspector, or replace the main window. Performance close, range replacement, refresh, or discarded completion SHALL release only Performance traversal. Store replacement and shutdown SHALL cancel and join both traversal owners. Raw reveal SHALL validate source, release Performance traversal while retaining the last complete dashboard presentation and its memory reservations, refresh the retained Event traversal snapshot, resolve and preflight the exact identity and durable detail through the still-active Explorer, focus the main window only after exact reveal succeeds, restore Inspector visibility, and resume exactly one Performance projection for the unchanged scope when allowed. If Event presentation is paused, refresh SHALL replace only the bounded Store snapshot, preserve the frozen Timeline and Pause state, and report failure instead of publishing a false reveal. Failed preparation, resolution, missing durable detail, or final Explorer acceptance SHALL preserve the prior Event selection and Inspector and retain Performance focus for its fixed guidance. Superseding window, Device, range, Store, raw-request, or shutdown transitions SHALL cancel and join a pending exact-reveal preflight and SHALL revalidate revision and target after any awaited acceptance. A paused Performance presentation SHALL retain its immutable presentation without a projection successor until Resume. At most one traversal per surface SHALL be retained.

#### Scenario: Aggregated CPU bucket opens source

- **WHEN** CPU contributors differ from FPS contributors and the operator opens the CPU series
- **THEN** Viewer resolves CPU's deterministic contributing key and selects exactly that raw Event in the main window
- **AND** it never opens the bucket-wide or nearest unrelated Event
- **AND** the Performance window remains open with its Device, range, and pause state unchanged

#### Scenario: Events refresh during Performance traversal

- **WHEN** Events and Performance both request bounded Store work
- **THEN** one operation queue serializes actual SQLite access while retaining no more than one traversal per surface
- **AND** completion or cancellation from either surface cannot release or retarget the other traversal
