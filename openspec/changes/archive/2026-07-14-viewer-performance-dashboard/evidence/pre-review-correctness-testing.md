# Correctness and Testing Artifact Review

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Not approved for implementation.** The product boundary is coherent, and strict OpenSpec
validation passes, but ten correctness and testability findings remain. The current artifacts do not
yet define enough state to implement the Store continuation, range/bucket geometry, bounded memory,
gap preservation, live/durable merge, refresh liveness, availability precedence, raw reveal, Pause,
or Store-unavailable behavior without making product decisions in source code.

Configured signing and inspection of entitlements embedded in a signed product remain explicitly
deferred by product-owner decision to Goal-level `release-hardening`. That deferred gate is not a
finding in this review.

## Findings

### CT-1 — P1 (confidence: 10/10): residual-filter traversal has no exact continuation contract

The Store traversal caps one turn at 512 returned rows, 4,096 visited rows, 5,000,000 VM
instructions, or 50 ms, while explicitly accepting that the existing exact-device index applies the
Event-type predicate after range selection (`design.md:53-66, 170-174`;
`specs/viewer-local-store-search/spec.md:5-17`; `specs/viewer-performance-dashboard/spec.md:125-133`).
The artifacts do not say whether a continuation resumes after the last row **visited** or the last
performance row **returned**, whether a budget stop occurs before or after the current candidate,
or how a VM/time stop before the first returned row proves forward progress. Resuming from the last
returned row can repeatedly revisit thousands of non-performance Events; advancing after an
interrupted candidate can skip a valid snapshot. The relationship between the turn continuation,
the 512-row page cursor, bidirectional traversal, `hasMore`, and terminal completion is also absent.

Required remediation:

1. Define one frozen traversal token and an opaque scan continuation that binds direction, complete
   scope, Store generation, frozen upper row, and the exact last **examined** key independently of
   the last emitted key.
2. Define pre-row/post-row budget checkpoints, continuation behavior for an empty filtered turn,
   equal-time row-ID ties, and a monotonic-progress rule for VM/time exhaustion before emission.
3. State exactly when a partial page plus continuation is valid and when only a terminal complete
   result may be reported.
4. Add deterministic injected clock/VM/visit seams. Extend task 6.1 with 4,095/4,096/4,097
   nonmatching rows, 511/512/513 matching rows, zero-match turns, stops immediately before and after
   a matching row, repeated empty continuations, both directions if bidirectionality remains, and
   proof of no skip, duplicate, livelock, or lease leak. The 50-ms assertion must use the injected
   clock; host elapsed time is diagnostic only.

### CT-2 — P1 (confidence: 10/10): page, live-input, and projection accounting bounds contradict each other

Each Store page may contain 512 carriers with canonical content bytes, and typed content up to 64
KiB is accepted (`specs/viewer-local-store-search/spec.md:5-11`). That is already 32 MiB of content
before carrier overhead, while the dashboard claims at most 16 MiB of deterministically accounted
projection state (`specs/viewer-performance-dashboard/spec.md:61-86`). A greater-than-64-KiB Event
is classified invalid but the carrier contract still requires its canonical bytes, so one page can
retain substantially more. The active generation also owns an immutable live snapshot
(`specs/viewer-performance-dashboard/spec.md:125-129`), whose existing bound is separate from the
16-MiB cache claim. No exact cap exists for categorical transitions, gaps, invalid diagnostics,
in-flight pages, decoded intermediates, claimed MainActor delivery, or peak memory while a result is
built before LRU eviction (`design.md:82-109`).

Required remediation:

1. Add a checked aggregate page-byte limit and stop with a continuation before crossing it. Define
   64 KiB as exactly 65,536 canonical UTF-8 content bytes, checked from SQLite length before copying.
2. For oversized typed content, return bounded identity/length/invalid metadata without loading the
   complete raw JSON into the dashboard carrier; raw inspection must remain an Explorer reload.
3. Publish one deterministic accounting formula covering or explicitly separating active reducer
   state, completed cache entries, gap/transition/diagnostic state, Store pages, live snapshot
   references, decode buffers, and claimed delivery. Define the permitted peak, not only the final
   cache size.
4. Give categorical transitions, gaps, and invalid diagnostics exact count and byte caps, plus the
   conservative behavior when those caps are reached.
5. Extend tasks 2.1, 3.2, 6.3, and 6.7 with a 512-row near-limit page, oversized rows, simultaneous
   page/live/cache/delivery ownership, a single result exceeding the cap, four-to-five-entry LRU
   insertion, exact eviction order, and zero raw-buffer retention after cancellation/cleanup.

### CT-3 — P1 (confidence: 10/10): range anchors, bucket geometry, and cache identity are undefined

The artifacts name four ranges and a frozen upper Viewer time, but do not define the lower bound for
Current Session, the source of an ended/interrupted historical device bound, inclusive/exclusive
membership, checked subtraction at the monotonic origin, or behavior for an empty or zero-duration
session (`design.md:72-80`; `specs/viewer-performance-dashboard/spec.md:31-53`). They cap output at
512 aligned buckets without defining bucket width, origin, half-open boundary rules, the final upper
boundary, or how one/512/513 samples and equal timestamps map deterministically. A streaming
100,000-sample test cannot establish correctness without that grid.

The completed-cache key is also incomplete. There are four named ranges, yet task 6.3 requires a
four/five-entry eviction test. The artifacts do not say whether the key includes source/device,
range, frozen anchor, lower/upper bounds, Event upper row, Store/runtime/live generations, or data
revision. Reusing a current five-minute entry under a later anchor can show stale buckets and cards.

Required remediation:

1. Define a checked closed/open range convention and exact anchors for current, ended, interrupted,
   empty, and Current Session scopes.
2. Define a deterministic bucket formula from frozen lower/upper bounds, including width rounding,
   bucket origin, final-boundary inclusion, equal-time ties, and crosshair boundary selection.
3. Define the complete cache key, hit validity, current-source invalidation, LRU touch point, atomic
   insertion, and why a fifth distinct entry can exist.
4. Extend tasks 3.3, 6.3, and 6.4 with underflow/overflow boundaries, empty and one-tick ranges,
   exact bucket edges, 511/512/513 buckets, current-anchor advancement, historical interrupted
   sessions, stale cache rejection, and deterministic LRU ties.

### CT-4 — P1 (confidence: 10/10): gap and per-metric hole semantics cannot be preserved by the stated bucket model

The dashboard requires exact Store/live gaps to split every series, invalid snapshots to split the
sequence, and a missing metric to create only a metric-local hole
(`design.md:126-133`; `specs/viewer-performance-dashboard/spec.md:94-123`). The Store delta defines
only raw Event carriers; it does not define a gap input, frozen gap upper bound, gap continuation, or
how a Store gap is positioned in the monotonic chart domain
(`specs/viewer-local-store-search/spec.md:3-27`). A missing/unavailable sample or explicit gap can
also occur between measured samples that collapse into one aggregate bucket. A single min/max/sum
accumulator would hide that break and draw a line across it. Arbitrarily many gaps, invalid samples,
or categorical changes also conflict with 512 buckets and the unspecified bounded transition state.

Required remediation:

1. Define the exact durable and live gap source, frozen identity/upper bound, scope filter, ordering,
   and mapping into Viewer monotonic order. If a gap lacks an exact monotonic position, define a
   conservative sequence-identity rule rather than deriving order from wall time.
2. Define segment/break state inside or between buckets so no aggregate can bridge an explicit gap,
   invalid snapshot, unavailable interval, or metric-local hole.
3. Define behavior when break state exceeds its cap. Dropping a break must never reconnect points;
   conservative suppression of the affected remainder is acceptable if specified.
4. Extend tasks 3.4, 6.4, and 6.7 with gaps on bucket edges and inside buckets, repeated missing-only
   metrics, invalid storms, gap-cap overflow, wall-clock disagreement, and mutation-sensitive proof
   that no line is drawn across any forgotten boundary.

### CT-5 — P1 (confidence: 9/10): current live/durable freeze order can lose or double count a sample

The artifacts require one immutable live snapshot, one frozen durable upper row, exact-journal-key
deduplication, and durable identity preference, but do not define an atomic capture/merge protocol
(`design.md:38-47, 175-176`; `specs/viewer-performance-dashboard/spec.md:3-17`). If the Store upper
row is frozen before a live snapshot and a transient Event becomes durable and leaves the live
window between those captures, the row can be above the frozen durable bound and absent from the
live snapshot. Capturing and reducing live first without an exact reconciliation rule can instead
double apply a later durable page. The mixed ordering key
`durableRowID-or-live-identity` also has no total order or stable replacement rule
(`specs/viewer-performance-dashboard/spec.md:38-42`).

Required remediation:

1. Define one current-scope freeze receipt containing the capture order and exact Store generation,
   Event upper row, runtime/live generation, source/device identity, anchor, and immutable live
   snapshot identity.
2. Define all durable-first/live-first outcomes, including durable rows above the frozen bound,
   transient eviction, identical/conflicting journal keys, and whether durable replacement updates
   representative identities without applying metric values twice.
3. Define a stable total tie order for live identities and prove changing representation from live
   to durable cannot move a sample between buckets.
4. Extend tasks 2.4 and 6.5 with a barrier-controlled permutation matrix around live capture,
   durable commit, frozen-upper capture, live reconciliation/removal, page reduction, cache
   completion, and raw reveal. Assert exactly one contribution and no missing sample in every order.

### CT-6 — P1 (confidence: 9/10): refresh can starve long scans, and staleness has no wake when sampling stops

Only complete frozen scopes may publish, while current Events can request refresh up to ten times
per second (`specs/viewer-performance-dashboard/spec.md:125-153`). If every refresh replaces an
active Current Session scan, a scan longer than one cadence can be cancelled forever and never
publish. “One latest refresh wake” bounds queued callbacks but does not define one active scan plus
a dirty successor or otherwise guarantee completion.

The stale-card scenario also requires state to change after sampling stops, but no new Event then
advances the current anchor or wakes presentation (`design.md:181-182`;
`specs/viewer-performance-dashboard/spec.md:101-123`). Without one owned freshness deadline, a card
that was fresh at the last frozen anchor can remain fresh indefinitely.

Required remediation:

1. Define refresh admission while work is active: one running generation plus at most one dirty
   successor is recommended. State whether new Events invalidate the result or merely schedule one
   successor, and guarantee eventual complete publication under sustained 10-Hz input.
2. Add one replaceable, cancellable freshness-deadline wake derived with checked arithmetic. Define
   equality at the deadline, anchor resampling, Pause behavior, and cleanup ownership without a
   repeating poll.
3. Extend tasks 3.5, 6.4, and 6.5 with a blocked 100,000-row scan plus 100,000 refresh tokens,
   sustained input across multiple cadences, sampling-stop deadline/equality tests using an injected
   clock, one dirty successor, one deadline owner, and zero work after replacement or cleanup.

### CT-7 — P2 (confidence: 10/10): availability precedence and mixed-bucket state are ambiguous

The Core V1 model permits a known value and a matching `unavailable` record in the same decoded
snapshot, and permits repeated unavailable keys with different reasons. The artifact lists present,
unavailable, absent, invalid, and stale states but does not define conflicts or precedence
(`design.md:111-124`; `specs/viewer-performance-dashboard/spec.md:94-104`). It also does not say
whether a latest invalid snapshot replaces earlier valid card values, whether a latest valid sample
with one absent metric falls back to an older metric value, or whether current cards are scoped to
the selected chart range.

Within a bucket, measured, missing, and unavailable observations can coexist. The tooltip promises
one availability plus numeric statistics without defining whether measured values still aggregate,
which state is displayed, or how a categorical `.unknown` differs from absent/unavailable. Task 6.2
tests each state independently but not contradictory or mixed input (`tasks.md:38-40`).

Required remediation:

1. Define duplicate unavailable-key handling and value-plus-unavailable precedence, either as a
   deterministic state rule or an invalid snapshot.
2. Define latest-card semantics for invalid snapshots, metric-local absence, stale data, and range
   changes; do not silently carry forward an older value unless that is explicitly the contract.
3. Define bucket statistics and availability when measured and nonmeasured samples coexist, plus
   categorical `unknown` presentation.
4. Extend tasks 6.2 and 6.4 with duplicate/conflicting unavailable records, present-plus-unavailable,
   latest-invalid, latest-missing-one-metric, enum unknown, mixed buckets, and selected-range versus
   current-card behavior.

### CT-8 — P2 (confidence: 10/10): representative identity is not tied to the metric being revealed

The artifacts alternate between one representative per numeric accumulator and one representative
per bucket (`design.md:103-106, 147-153`;
`specs/viewer-performance-dashboard/spec.md:63-75, 155-172`). In a bucket where CPU, FPS, and
battery are present in different samples, a bucket-wide center-nearest Event may not have contributed
to the CPU aggregate selected by `Open Source Event`. The exact tie-break for samples equally distant
from the center is also absent despite task 6.3 requiring representative-tie tests. A cached live
representative can later become durable; the artifacts do not say whether reveal follows the exact
journal key to the durable row or reports the old transient identity unavailable.

Required remediation:

1. Choose metric/series-specific representative identities from samples that actually contributed
   to that accumulator, or explicitly define a bucket-wide action whose label does not claim to
   trace the selected metric.
2. Define the center distance domain and complete tie-break using stable Viewer time and journal
   identity, independent of live/durable representation.
3. Define how a representative transitions from still-live to durable after cache completion and
   how source generation, deletion, eviction, and Store replacement affect reveal.
4. Extend tasks 6.3 and 6.6 with disjoint metric contributors, center ties, live-to-durable
   transition before and during reveal, stale/deleted representatives, and mutation-sensitive proof
   that no nearby Event is selected.

### CT-9 — P2 (confidence: 9/10): Pause does not define source, device, range, or reveal changes

Pause freezes cards, charts, crosshair, and scroll while source/device/range replacement separately
invalidates generations and cache invalidation continues
(`specs/viewer-performance-dashboard/spec.md:135-153`;
`specs/viewer-event-explorer-control/spec.md:5-16`). The artifacts do not say whether changing the
source or device while paused immediately clears old performance content, whether range changes are
accepted and reflected only on Resume, or whether a frozen crosshair may still request raw reveal.
Freezing old-device values under a newly selected device would be a correctness and privacy defect;
clearing them would technically violate an unconditional reading of “Pause SHALL freeze.”

Required remediation:

1. Distinguish presentation-refresh Pause from authoritative scope replacement. Source/device/runtime
   replacement must clear or replace old content immediately even while paused.
2. Define paused range changes, mode switches, cache invalidation, crosshair/reveal availability,
   and the exact scope used by the one Resume projection.
3. Extend tasks 6.5 and 6.6 with every source/device/range/mode/reveal transition while paused,
   claimed MainActor delivery before Pause, replacement while frozen, repeated Resume, and proof that
   no old metric or identity appears under a new scope.

### CT-10 — P2 (confidence: 10/10): Store-unavailable behavior is tested but not specified

The proposal and projection requirement name durable and bounded transient Events as raw authority,
and task 6.5 requests storage unavailable/recovered tests (`proposal.md:10-17`;
`specs/viewer-performance-dashboard/spec.md:3-17`; `tasks.md:41`). No normative rule states what the
dashboard publishes when a historical Store is unavailable, when current scope has only a bounded
live snapshot, or when Store failure occurs after some durable pages have been reduced. “No
partial-complete chart” conflicts with showing a live-only current chart unless the result is
explicitly classified as incomplete with a conservative range gap. Recovery behavior and whether a
previous completed chart remains visible are also undefined.

Required remediation:

1. Define historical unavailable, current live-only unavailable, mid-scan failure, and recovery as
   separate states.
2. State whether a current live-only projection may publish, how it discloses the missing durable
   interval, whether prior complete data remains visible, and why it is not a partial-complete claim.
3. Define cancellation/lease/cache behavior on failure and require recovery to start one explicit
   fresh frozen scope without merging partial predecessor buckets.
4. Extend tasks 3.4, 3.5, 6.4, and 6.5 with unavailable-before-start, failure after first/middle/final
   page, live-only overflow/eviction, recovery before/after Pause, stale completion, and exact zero
   retained predecessor work.

## Existing coverage that should be retained

The following artifact decisions are sound and should survive remediation:

- one raw Event authority and no derived SQLite persistence;
- exact single-device scope and no reconnect-spanning or multi-device overlay;
- Viewer receive-time ordering rather than App-clock ordering;
- Core V1 bounded decode with unknown future fields remaining raw-only;
- generation invalidation before cancellation, joined claimed delivery, and complete lifecycle
  clearing;
- no partial-complete publication, interpolation, fabricated metrics, or derived-data export; and
- complete Viewer/package/static validation plus a requirement-to-evidence audit before archive.

## Validation performed

All active artifacts were read in full. Structural validation currently passes:

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

This confirms OpenSpec structure, not closure of the semantic findings above.

## Unresolved finding count

**10**
