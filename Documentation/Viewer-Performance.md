# NearWire Viewer Performance Dashboard

## Scope

The Performance dashboard is a native macOS analysis view for the built-in
`nearwire.performance.snapshot` Events received from one exact App session. Select one source and
one device in **Sources & Devices**, then choose **Performance**. A merged multi-device selection is
not accepted because device clocks, lifecycle boundaries, and metric capabilities are not
interchangeable.

The dashboard is a projection of ordinary Events. It does not add another network protocol,
database, sampler, acknowledgement path, or persistence format. Raw recorded Events and the bounded
current live window remain authoritative. The dashboard can be rebuilt from those inputs and never
writes derived buckets back to the store.

## Ranges and time

The range picker provides **1 min**, **5 min**, **15 min**, and **Session**. Five minutes is the
default. A fixed range ends at the frozen analysis anchor and is clipped to the selected device
session start. Session begins at that start. Both ends are inclusive.

NearWire orders samples by Viewer monotonic receive time. The Viewer wall receive time supplies
human-readable labels. App `sampledAt` values remain available in the raw Event, but they never
reorder charts or merge timelines. This avoids clock skew and wall-clock changes on the phone.

A current range first freezes the bounded live projection, then freezes durable Event and gap upper
bounds. Exact journal identities reconcile a live Event with its later durable row without counting
the sample twice. An Event accepted after the live freeze belongs to the next refresh. A historical
range uses the selected session's frozen end or recording upper bound and never compares that old
monotonic clock with the current Mac uptime.

## Current cards and availability

The **Current** section has 12 cards: estimated and maximum frame rate, CPU, memory footprint,
battery level and state, thermal state, Low Power Mode, App-to-Viewer queue depth, dropped Events,
and App-to-Viewer and Viewer-to-App byte rates.

Cards use the latest raw performance Event at or before the range anchor, looking back at most 180
seconds even when that extends before the chart range. A valid snapshot is fresh for the smaller of
180 seconds and the larger of three sample intervals or three seconds. An unreadable or invalid
snapshot uses three seconds. Reaching the deadline is stale: all cards show **No recent sample**.
Current cards expire from one exact deadline callback; historical cards are evaluated once against
their frozen anchor and do not run a timer.

The **Availability** section always covers the closed 16-metric inventory. It distinguishes a
measurement, **Invalid snapshot**, **Permission denied**, **Temporarily unavailable**,
**Disabled**, **Unsupported**, and **Not collected**. Zero, `false`, and categorical `Unknown` are
measurements rather than missing data. A missing metric never borrows an older value. GPU
utilization, power in watts, and temperature in Celsius are availability-only in V1; NearWire does
not fabricate values the public iOS APIs did not provide.

| Metric | Display unit | Current card | Trend chart |
| --- | --- | :---: | :---: |
| Estimated frame rate | fps | Yes | Yes |
| Maximum frame rate | fps | Yes | Yes |
| App-process CPU | % | Yes | Yes |
| App-process memory footprint | bytes | Yes | Yes |
| Battery level | % | Yes | Yes |
| Battery state | state | Yes | No |
| Thermal state | state | Yes | No |
| Low Power Mode | state | Yes | No |
| GPU utilization | % | No | No |
| Power | W | No | No |
| Temperature | degrees Celsius | No | No |
| App to Viewer queue | Events | Yes | Yes |
| Viewer to App queue | Events | No | Yes |
| Dropped Events | Events | Yes | Yes |
| App to Viewer rate | bytes/s | Yes | Yes |
| Viewer to App rate | bytes/s | Yes | Yes |

Memory and throughput values use bounded human-readable byte formatting in the UI. Battery is
encoded as a fraction but displayed as a percentage. CPU may exceed 100% for multi-core App work.
Frame rate is display-callback cadence, not GPU utilization or proof that frames were rendered.
See [SDK-Performance.md](SDK-Performance.md) for the collection definitions.

## Buckets, charts, and crosshair

The inclusive range is divided into no more than 512 equal-width monotonic buckets. Bucket width is
the ceiling of range span divided by 512; the final bucket is clipped to the upper bound. A sample
on an interior boundary belongs to the later bucket.

Each numeric series stores finite minimum, average, maximum, measurement count, nonmeasurement
counts, continuity, and one metric-specific representative Event identity. It does not retain the
raw sample list. The six chart groups are Frame Rate, CPU, Memory, Battery, Throughput, and Queues
and Drops. An average line and min-max envelope describe each aggregate; an absent measurement is
not plotted as zero.

Hover or drag sets one crosshair shared by every chart. Left and right move across buckets; up and
down cycle metrics in the focused chart. The selected aggregate reports its Viewer-relative span,
sample count, min/average/max, nonmeasurement counts, and whether the series is continuous. Clear
releases the selection and tooltip state. Accessibility exposes at most 64 evenly selected bucket
summaries per chart, including the first and last.

## Gaps and discontinuities

Gaps are diagnostic evidence, not fabricated Events. An App-to-Viewer gap can break a series;
Viewer-to-App-only gaps do not. Unknown direction or applicability stays conservative.

A gap with a trustworthy wall-time interval is placed only when it overlaps one unique bucket wall
envelope. An interval-less, invalid, ambiguous, nonoverlapping, hidden applicable, or overflowed gap
becomes an **Unplaced gap** and suppresses every inter-bucket line segment for the range. Points and
min-max envelopes may remain visible. NearWire never guesses a monotonic position from an
unreliable wall interval.

Adjacent samples also split when their receive-time distance reaches the freshness horizon derived
from their intervals. An invalid snapshot breaks every metric. A missing or unavailable value
breaks only that metric. At most 128 gap details and 128 invalid-snapshot details are retained;
additional evidence increments bounded loss accounting and cannot reconnect a line.

## Open the source Event

**Open Source Event** uses the selected metric's representative journal key at action time. It
switches through the shared Events/Performance traversal coordinator, then asks Event Explorer for
that exact row. A durable locator is preferred; the exact still-live row is the fallback. Deleted,
evicted, stale, or unavailable content produces fixed guidance. NearWire never opens a neighboring
Event, passes copied JSON between controllers, or exports a derived bucket.

## Refresh, pause, and cleanup

At most one projection scan runs, with at most one dirty successor. Repeated change notifications
do not create one task per Event or continuously cancel useful work. Current refresh is capped at
ten publications per second and one per main run-loop turn.

**Pause** freezes the complete presentation. It does not pause network receive, live admission,
durable storage, retention, or session flow control. While paused, NearWire keeps only bounded dirty
state. **Resume** performs one fresh projection. Changing source, device, runtime, or analysis mode
invalidates and joins prior work before the successor owns the shared traversal. Cleanup clears
projection work, deadline receipts, cache, cards, buckets, gaps, invalid details, crosshair,
tooltip, and raw-resolution work. Late results from an old generation are rejected.

When durable storage is unavailable, a historical selection shows **Storage unavailable** and no
partial or cached chart is presented as current evidence. A current selection may instead rebuild
from one fresh bounded live slice and is labeled **Live window only**. That fallback starts with an
unknown-history discontinuity, discloses any bounded live-window overflow, and never claims
**Complete Range**. It does not reuse a failed durable reducer or merge predecessor partial work.
When storage recovers, NearWire starts one fresh scope; while paused it records only one dirty
successor and waits for **Resume**. Historical recovery likewise performs a fresh projection rather
than reviving the unavailable result.

## Deterministic bounds

The projection streams arbitrarily long recorded history while keeping resident and per-turn work
bounded:

| Resource | Maximum |
| --- | ---: |
| Buckets | 512 |
| Completed cached ranges for the selected source/device | 4 |
| Detailed gaps | 128 |
| Invalid-snapshot details | 128 |
| Charts | 6 |
| Total chart marks | 12,288 |
| Accessibility bucket summaries per chart | 64 |
| Raw Event content decoded per Event | 65,536 bytes |
| Event candidates examined per Store turn | 4,096 |
| Matching Event carriers emitted per page | 512 |
| Copied Event content per page | 4,194,304 bytes |
| Gap carriers per page | 32 |
| Events decoded per cooperative turn | 64 |
| Completed projection result | 8 MiB |
| Shared derived-state accounting ledger | 16 MiB |
| Deterministic peak including concurrent pages, live slice, and decoder | 25,805,312 bytes |

Store Event turns use a 5,000,000 SQLite-instruction budget and a 50 ms injected logical deadline;
gap classification uses its own bounded work. These are cancellation/work gates, not elapsed-time
service guarantees. The byte accounting is a deterministic ownership contract, not a claim about
the Swift allocator's exact heap footprint. Limit exhaustion publishes fixed guidance and never a
partial result marked complete.

## Privacy and exclusions

Projection state contains aggregates, bounded diagnostics, and journal identities, not raw JSON.
Content-bearing work is generation-bound and prepared off the main actor. Reflection and debug
descriptions of projections, chart points, tooltips, and model diagnostics are redacted. The
dashboard adds no logging, analytics, clipboard, drag, share, file export, restoration, or derived
history. Raw Event content remains governed by Event Explorer's privacy and JSON-export rules.

V1 intentionally excludes multi-device or reconnect-spanning overlays, custom formulas, alerts,
thresholds, annotations, MetricKit payloads, interpolation, third-party charts, derived-data export,
dashboard persistence, a performance-specific transport, a second database, and changes to SDK
sampling.

Dashboard development and CI may use unsigned Viewer builds. That validates compilation, behavior,
resource contracts, and cleanup but does not validate the login-Keychain cross-update boundary.
Before release, run the stable-signer update gate documented in
[Viewer-Foundation.md](Viewer-Foundation.md). In the current Goal workflow that configured signed
gate is intentionally deferred to final release hardening; unsigned evidence must not claim it.
