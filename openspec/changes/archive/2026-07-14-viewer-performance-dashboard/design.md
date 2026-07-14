## Context

The Core module already owns the versioned `nearwire.performance.snapshot` schema and the optional
iOS monitor already submits it as an ordinary keep-latest Event. The Viewer now has one raw Event
journal, bounded transient live projection, generation-bound Store gateway, Event Explorer, and
single-window device/source selection. It has no typed performance query or chart presentation.

The dashboard must remain an analysis view over Events rather than a new telemetry protocol. A
snapshot can be durable, transient while storage is unavailable, malformed, missing individual
metrics, or explicit about why a metric is unavailable. Viewer receive order remains authoritative
across phones. V1 is single-device only, supports macOS 13/Swift 5, and may use the system Charts
framework but no package dependency.

## Goals / Non-Goals

**Goals:**

- Decode the existing Core V1 snapshot without changing its wire or public SDK API.
- Present one exact device session with current cards, aligned charts, explicit gaps and
  unavailable states, four fixed time ranges, and raw-Event traceability.
- Stream and aggregate arbitrarily long current-session history with constant-bounded retained
  projection state and cancellation between finite work turns.
- Reconcile raw durable and bounded transient Events by exact journal identity without double
  counting or inventing samples.
- Keep all content-bearing work generation-bound, off the MainActor, redacted in reflection, and
  joined during Viewer lifecycle cleanup.

**Non-Goals:**

- Multi-device or reconnect-spanning overlays, custom formulas, alerts, thresholds, annotations,
  MetricKit payloads, third-party charts/renderers, derived-data export, or dashboard persistence.
- A schema-3 migration, SQLite projection table, second database, hidden performance transport, or
  change to SDK sampling.
- Interpolation, fabricated GPU/power/temperature values, or treating missing data as zero.

## Decisions

### 1. Raw Event remains the only source of truth

`ViewerPerformanceProjectionStore` is a Viewer-internal serial in-memory owner. It retains only
decoded summaries, bucket accumulators, bounded diagnostics, and stable journal keys. It stores no
raw JSON and persists nothing. The durable path streams raw Events; the current path uses one
bounded live slice and reconciles exact journal keys. A projection can always be rebuilt.

Core `NearWireInternal` SPI owns the closed ordered 16-key `PerformanceMetricKey` inventory, group,
and numeric/categorical/unavailable-only kind. The SDK removes its internal duplicate and Viewer
uses the same schema vocabulary. This changes neither public API nor encoded JSON.

A schema-3 `PerformanceSamples` table was rejected for V1 because migration, backfill, invalidation,
and two-source consistency cost more than the measured need for a four-range streaming cache.

### 2. Specialized traversal scans candidate rows with a last-examined continuation

The query arbiter owns one forward-only performance traversal. Its scope binds Store generation,
recording/device IDs, inclusive Viewer monotonic bounds, frozen Event/gap uppers, and an opaque last-
examined `(viewerMonotonicNs, rowID)` continuation. The existing device timeline index scans Event
metadata in ascending order; `eventType` is a residual filter. Matching and nonmatching candidates
both advance the continuation, independently of the last emitted performance row.

A turn examines at most 4,096 candidates, emits at most 512 carriers, and copies at most 4,194,304
canonical content bytes. Each carrier charges 512 fixed bytes and the page wrapper 4,096, so a page
is at most 4,460,544 accounted bytes. SQLite reads `eventType` and `length(contentJSON)` before content. Content longer
than exactly 65,536 UTF-8 bytes yields identity, length, and an invalid marker without copying JSON.
If the next valid row would exceed page bytes, the turn stops before examining it so the next page
retries that row. A zero-match turn still advances through examined ordinary Events.

Injected VM and monotonic-clock seams gate 5,000,000 instructions and 50 ms. Cancellation is checked
before stepping. VM/time equality after an examined candidate yields at that candidate. Exhaustion
before the first candidate is a terminal work-limit result, not a retrying empty continuation. Host
elapsed time is diagnostic only. Store replacement closes the exact traversal and cannot retarget.

The ordinary Explorer filter/renderer path was rejected because it is retained-page presentation,
not a whole-range streaming reduction.

### 3. Current freeze, ranges, bucket geometry, and cache keys are exact

Samples order by Viewer monotonic receive time; Viewer wall time labels the axis. App `sampledAt`
never reorders. Historical upper bounds use exact device end monotonic time or the frozen recording
upper for an interrupted session; empty sessions use start for both bounds.

Current freeze first asks the live projection executor to drain bounded accepted ingress and return
one immutable performance slice, exact connection/live generation, and anchor. Store Event/gap
uppers freeze afterward. Durable rows are filtered at/before the live anchor and merged with the
slice by journal key. Anything after live freeze is outside the anchor; anything at/before it is in
the frozen slice even if its durable commit races. Durable representation replaces only the locator,
never applies metrics twice or changes time/bucket.

Ranges are inclusive `[lower, upper]`. Fixed lower is
`max(deviceStart, upper - (durationNanoseconds - 1))` with checked saturation; Current Session starts
at device start. Zero duration is one tick. Checked span is `upper - lower + 1`; bucket width is
`ceil(span / 512)`, count is `ceil(span / width)`, and index is `(time - lower) / width`. The final
bucket includes upper; an interior exact edge chooses the later bucket. Equal-time samples use the
canonical journal tuple order defined below.

The cache key includes source/device identities, range kind, lower/upper, Store generation,
Event/gap uppers, runtime/live generations, and live slice revision. Exact hit or successful
publication touches LRU. Atomic fifth insertion evicts oldest touch then canonical tuple order. A moving
current anchor creates a new key. Source/device replacement clears the global cache. Source
generation remains presentation authority rather than cache identity: before reusing an exact-key
entry, every retained representative must match the active generation. A same-key entry from an
older range-transition generation is atomically replaced by the already-owned incoming result before
publication, so raw reveal never inherits stale generation authority.

Canonical journal order compares runtime UUID 16 network-order bytes, connection UUID bytes,
direction ordinal (`appToViewer=0`, `viewerToApp=1`), then big-endian wire sequence. Cache order
compares source-kind ordinal (`current=0`, `historical=1`), source UUID or sign-bit-flipped big-endian
positive row ID, device UUID/row ID, range ordinal (one/five/fifteen/session), lower, upper, Store
generation, Event upper, gap upper, runtime UUID, live generation, then slice revision. UUID and
integer comparisons use raw bytes/unsigned values, never locale, description, hashing, or live versus
durable locator. These tuple orders are the only LRU/representative tie-break or lexical meaning.

### 4. One ownership ledger bounds all derived and scratch state

One generation owns one reducer, Store traversal, bounded live slice, and at most four completed
entries for only the current source/device. Each result has at most 512 buckets, ten numeric
accumulators per bucket, three categorical first/latest/last states with saturating change counts,
per-metric discontinuity flags, 128 detailed gaps, 128 invalid diagnostics, one saturating detail-
loss counter, the fixed 16-key inventory, and metric-specific representative journal keys. No Event-
sized side list exists.

Deterministic accounting constants are: controller/source base 4,096; cache key 256; result base
4,096; bucket 2,048; detailed gap 256; invalid diagnostic 128; availability entry 64; model wrapper
1,024; delivery wrapper 256; tooltip 2,048; crosshair 64; Event carrier 512 plus copied content;
normalized gap carrier 256. A result charges its base + key + buckets + details + diagnostics +
16 availability entries. Active reduction charges the same formula at its current counts. Model and
delivery reference an immutable charged result rather than duplicating it; distinct pending results
are independently charged. Static labels and lazily generated Chart marks retain no separate model
objects.

Each completed result is at most 8 MiB. A shared ledger caps controller, active reducer, cache,
presented model, pending/processing delivery, tooltip, crosshair, diagnostics, and identities at
16,777,216 bytes. One Store Event page is at most 4,460,544 bytes. One live slice is at most
4,493,312 bytes including its 4,096 wrapper and up to 128 normalized live gaps. One Store gap page is
at most 8,704 bytes (512 wrapper + 32 carriers), and one decoder buffer is 65,536. All may coexist,
so exact deterministic peak is 25,805,312 bytes, not a Swift heap guarantee. LRU eviction precedes
insertion; a still-oversized result fails with fixed guidance and publishes no partial chart.

The ten numeric metrics are estimated/maximum FPS, CPU, memory, battery fraction, uplink/downlink
bytes per second, uplink/downlink queue depth, and dropped count. Each accumulator keeps finite
min/max/sum/count, first/last times, nonmeasurement counts, and one center-nearest contributing key;
ties use earlier Viewer time then the canonical journal tuple order. Six charts create at most 12,288 marks total,
one tooltip is retained, and at most 64 bucket summaries per chart enter accessibility.

### 5. Availability and cards use a closed precedence

Present values, including zero and categorical `.unknown`, are measurements. Explicit reasons are
Unsupported, Disabled, Permission denied, and Temporarily unavailable. Absence is Not collected.
Any duplicate known unavailable key or known present-plus-unavailable conflict makes the entire
snapshot Invalid; unknown future fields/keys remain raw-only.

Cards locate the latest raw performance Event at/before the anchor within a fixed 180-second
lookback, even beyond chart lower bound. If none exists, every card is No recent sample and no
deadline is armed. Otherwise freshness is decided before typed status. A valid positive header uses
`min(180 seconds, max(3 * interval, 3 seconds))`; an invalid/unreadable header uses three seconds.
Equality is stale and No recent sample wins over Invalid/unavailable/not-collected. Only a fresh
latest Event is decoded for card state: invalid means Invalid; missing/unavailable never falls back
to an older metric. Range changes do not change card identity.

Every current-source card result carries source generation, latest-Event journal key, absolute
Viewer-monotonic freshness deadline, and a monotonically advancing deadline revision. The MainActor
delivery gate validates all four values and the injected current-uptime clock both when claiming and
when applying a result. If `now >= deadline`, chart data may publish but every card is restated as No
recent sample and no deadline is armed. A callback mutates cards only when generation, Event identity,
deadline, and revision still match; it is scheduled only when `deadline > now`, fires at most once,
and never re-arms an elapsed deadline. While paused, expiry records one bounded dirty bit without
mutating frozen presentation; Resume performs one fresh projection whose apply-time clock check is
authoritative. Source/runtime replacement invalidates the receipt before joined cleanup.

Historical cards never compare persisted monotonic values with current uptime and never schedule a
freshness callback. They evaluate the same latest-Event/horizon rule once against the frozen
historical upper anchor in that recording's monotonic domain. A latest Event whose checked distance
to the upper is at or beyond the horizon is No recent sample; otherwise its typed state is frozen.
Historical Pause changes no time state. Switching current/historical scope invalidates and joins the
prior receipt before the successor evaluates in its own clock domain.

Buckets aggregate measured values and count every nonmeasurement state separately. Tooltip shows
both. With no measurement, precedence is Invalid, Permission denied, Temporarily unavailable,
Disabled, Unsupported, then Not collected.

### 6. Gap mapping is conservative under schema 2

The frozen scope includes exact-device/recording Store gap upper plus bounded live gaps. Store
normalizes each gap row into one fixed 256-byte carrier containing only row/scope identity, an
`eventLoss`, `storageContinuity`, `controlContinuity`, `lifecycleContinuity`, `presentationLoss`, or
`unknown` kind; a `performance`, `irrelevant`, or `uncertain` applicability; its wall interval; and
count. Variable namespace/reason/direction strings never cross the traversal.

Store kind mapping uses case-sensitive ASCII exact/prefix comparison and is closed:
`missingInitialEvent.*` is eventLoss; `storageUnavailable`,
`midRuntimeRetry`, `liveStart`, and `store*` are storageContinuity; `uplinkDisposition*`,
`dropJournal*`, and `policyJournal*` are controlContinuity; `deviceClose*` and `shutdownStructural*`
are lifecycleContinuity; `coalescedOverflow` and every unrecognized reason are unknown. Direction
maps independently: `appToViewer` and `both` are performance, `viewerToApp` is irrelevant, and
`unknown` or any unrecognized value is uncertain. Live ingress/window overflow is eventLoss; Store
unavailable/recovery is storageContinuity; resident conflict is presentationLoss; diagnostic loss is
unknown; every positive live counter is uncertain because it has no exact direction or wall
interval. Unknown input always remains conservative.

Irrelevant carriers are counted but do not break a performance series. Performance or uncertain
Store carriers are placed only when their valid wall interval overlaps one unique monotonic bucket
envelope. The fixed 512-byte Store gap-page wrapper carries generic `hasMoreRows`, a saturating total
performance-or-uncertain count, and `hasMoreApplicableGaps`. Store normalizes/classifies the complete
frozen matching metadata scope under its cancellation, VM, and injected-time budget before deciding
the applicable overflow bit; classification budget exhaustion is conservatively applicable. Hidden
irrelevant-only rows set only generic pagination and never break a series. Any hidden performance or
uncertain row sets `hasMoreApplicableGaps`; budget exhaustion returns that bit true regardless of the
partial count and never claims classification complete.

An interval-less applicable live carrier, invalid interval, wall regression, ambiguous/nonoverlap
mapping, Store/live `hasMoreApplicableGaps`, or more than 128 combined applicable details sets
Unplaced gap and suppresses every inter-bucket line segment for the range. The live-slice wrapper
carries the same saturating applicable count and applicable-overflow bit; it retains no more than 128
carriers and sets the bit whenever applicable input/detail exceeds retained evidence. Points and
envelopes may remain; Viewer never guesses a monotonic position.

Adjacent samples split at
`min(180 seconds, max(3 * max(previousInterval, currentInterval), 3 seconds))`. Invalid snapshots
set every metric discontinuous; a missing/unavailable metric sets only its metric flag. Any break
inside a bucket prevents its aggregate connecting to either neighbor. Overflow retains bucket break
flags plus one saturating loss count, so forgotten detail never reconnects a line.

### 7. Cards, availability, synchronized charts, and refresh share one projection

Cards cover FPS, CPU, memory, battery level/state, thermal state, low-power mode, uplink queue, drops,
and conditional byte rates. A fixed 16-key availability section includes unavailable-only GPU,
power, and Celsius temperature without numeric fabrication.

Charts group display, CPU, memory, battery, throughput, and queue/drop. One crosshair time selects
all charts; the selected series uses its metric-specific representative. Tooltip reports span,
count, min/average/max, nonmeasurement counts, discontinuity, and aggregation.

Refresh owns one running frozen scan and at most one dirty successor. New tokens do not cancel the
running scan; it may publish, then one successor uses the latest token, guaranteeing progress under
10-Hz input. For current scope only, one replaceable injected-clock freshness deadline is armed only
for a strictly future absolute deadline and is bound to source generation, latest Event identity, and
deadline revision. Claim and apply revalidate the current uptime clock; equality marks stale without
polling or re-arm. Historical scope uses its frozen upper in its own recording domain and owns no
deadline wake. Pause freezes presentation while current expiry retains one dirty bit. Scope
replacement/cleanup invalidates the receipt and cancels the deadline. Cancellation may be
cooperative, so one deadline owner keeps one reschedulable physical worker for its lifetime. Each arm
replaces only the logical receipt and deadline on that worker; invalidation disarms it without
creating another worker. Cleanup cancels and joins that same worker before its receipt completes.
Repeated re-arming therefore retains one logical wake and one physical worker rather than a growing
set of cancelled handles.

### 8. Raw traceability resolves a stable metric-specific journal key

Each metric accumulator stores a contributing journal key, not a copied Event or bucket-wide guess.
Live-to-durable reconciliation updates only its locator. Open Source Event resolves that key at
action time, preferring durable then still-live. Explorer performs a fresh exact reload. Deleted,
evicted, stale, or unresolvable keys show fixed guidance without selecting a neighbor. No JSON,
metric, bucket, or tooltip crosses controllers; derived buckets are never exported.

### 9. One analysis-mode coordinator owns traversal switching and cleanup

The workspace gains Events/Performance while retaining one source column and composer. Performance
requires exactly one device. `ViewerAnalysisModeCoordinator` serializes the shared query arbiter:
Events-to-Performance invalidates/joins Explorer query/detail work and releases its traversal before
Performance starts; Performance-to-Events invalidates/joins the scan and releases its traversal
before Event work or raw reveal starts. Reveal validates source, performs this order, switches mode,
then submits the key. At most one mode owns an active traversal; cached presentation owns no lease.

Pause freezes refresh only for unchanged source/device/range. Runtime/source/device replacement
immediately invalidates, joins, and clears cache/model/delivery content even while paused. Store
status carries the installed explorer-coordinator generation: unchanged generation is an ordinary
refresh, while a changed generation advances performance source generation, invalidates raw reveal,
clears all presentation and cache authority, and performs a coordinator-owned two-phase replacement.
The controller first invalidates without auto-rebuilding. In parallel, Explorer clears predecessor
Store-derived rows, targets, prepared delete/export authority, and pending destination selection
synchronously. A Store-committed export is instead cancellation-requested and retains its execution
slot until the authoritative completion publishes. Explorer deactivates Event traversal and owns one
rematerialization receipt through the replacement change snapshot, first catalog pages, and bounded
exact logical-ID lookups for a selected recording or up to 16 selected devices outside those pages.
The first device-page transaction revalidates the recording page's frozen global catalog bounds
before minting device-scoped bounds. Catalog-change retries, including any mismatch between those
two phases, restart from one new frozen recording generation. Terminal Store failure commits an
empty/failed catalog state before completing the receipt. It retains the operator's logical source
and device selection but clears all partially committed catalog rows, operation targets, and device
mappings. The unresolved authority state rejects later historical filter/device/paging/management
materialization and selected-recording presentation even if an ordinary refresh presents a matching
logical row or reused numeric row ID. Source selection is serialized with the receipt: selecting
another historical row cancels the pending device request and restarts the whole bounded catalog
phase for the new logical identity; selecting Live cancels all active catalog requests, clears partial
Store identity, completes the receipt exactly once, and compiles only a live request with no durable
recording identity or device mapping. If a later ordinary refresh repopulates historical rows while
authority remains unresolved, selecting one deactivates and clears that live scope and opens a new
rematerialization receipt for the selected logical identity. That user-owned receipt is routed to
the analysis coordinator: Events reactivates only after the receipt, while Performance clears and
rebuilds guidance or target only after the same barrier. A failed historical compile never leaves
Live running under a historical label. Only a successful exact recording lookup returning no row
can automatically reset a historical source to Live. A Store-change signal arriving during
rematerialization remains one dirty bit and starts
exactly one successor snapshot afterward. The coordinator joins the prior mode transition,
controller cleanup, raw resolver, Event deactivation, and Explorer rematerialization receipt before
reactivating Events, recompiling target/guidance, and admitting exactly one successor. Numeric row-ID
reuse cannot cross that barrier. A selected logical device that is absent remains an explicit
no-match selection with no durable query or performance target; it never collapses to the empty-
selection meaning of all devices.
A paused range change clears crosshair/tooltip, records desired range, and waits for one Resume
projection. Reveal while paused is allowed only for unchanged frozen scope. Mode switch clears active
work and crosshair; same-source completed cache remains under the global ledger.

Cleanup also owns the freshness deadline and clears cards, buckets, categorical state, diagnostics,
decoded summaries, live slice, cache, locators, and delivery values before the existing receipt. An
isolated unsealed controller deinitializer seals an externally retained model synchronously, then a
small detached cleanup registry retains only cancellation/join owners until the run, delivery pump,
and deadline work all finish. Performance content stays out of logs, preferences, restoration, safe
rows, clipboard, drag, share, and generic reflection.

### 10. Store-unavailable states never reuse partial work

Historical Store-unavailable scope shows only Storage unavailable. Current scope may publish a
separately labeled Live window only projection from a fresh bounded live slice, with leading unknown-
history break and live overflow disclosure; it never claims Complete Range. Failure before or during
a scan discards every partial bucket and releases traversal/lease. Current then starts a fresh live-
only generation; historical remains unavailable. A prior chart is cleared.

Recovery starts one new frozen scope and never merges predecessor partial/cache state. Recovery while
paused marks one dirty successor and waits for Resume.

## Risks / Trade-offs

- **Long scans** → finite last-examined pages, running-plus-dirty refresh, cancellation, and four
  completed entries; no partial-complete chart.
- **Residual Event-type filtering** → exact candidate/byte/VM/injected-time bounds and accepted plan;
  schema migration remains deferred until evidence requires it.
- **Wall-only schema-2 gaps** → conservative envelope mapping; ambiguity suppresses connections.
- **Live/durable races** → live-first freeze anchor plus later Store uppers and journal-key dedupe.
- **Large/malformed Events** → length-before-copy, 64-KiB typed limit, aggregate page/ledger caps,
  closed availability conflicts, and raw-only inspection.
- **Chart/accessibility growth** → exact bucket, diagnostic, mark, byte, and accessibility caps.
- **Sampling stops** → one owned freshness deadline shows No recent sample without polling.

## Migration Plan

1. Add the performance Store traversal and projection types without changing schema version 2.
2. Add controller/model integration and lifecycle cleanup behind the new Performance mode.
3. Add Swift Charts UI, accessibility, raw reveal, and English documentation.
4. Validate current and historical data, storage outage/recovery, long sessions, malformed snapshots,
   and lifecycle replacement.
5. Rollback removes the Viewer-only projection/UI code; raw Events and schema remain unchanged.

## Open Questions

None. Multi-device overlays and persistent projection caches remain explicit future changes and do
not block V1.
