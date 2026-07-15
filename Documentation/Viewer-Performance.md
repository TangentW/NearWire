# NearWire Viewer Performance Dashboard

## Scope

The Performance dashboard is a singleton native macOS window for the built-in
`nearwire.performance.snapshot` Events received from one exact App session. Open it with the
**Performance** button in the main Viewer header, then choose one Device in the Performance window.
The Performance Device is independent from the main Event filters, so changing either selection
does not silently retarget the other. A merged multi-device selection is not accepted because
device clocks, lifecycle boundaries, and metric capabilities are not interchangeable.

The main Viewer remains an Event workspace while Performance is open. Closing either window leaves
the other usable, and reopening Performance reuses the same process Session and Viewer runtime.
If macOS restores Performance without the main window, that window idempotently starts the same
single runtime; showing Main later does not start another listener or Session.
The Performance window opens at 1100 by 760 points and remains usable at its 800 by 600 point
minimum. **Show Viewer** returns focus to the main Event window without closing Performance.
The same action remains available while the runtime is starting or unavailable, so recovery does
not require closing the Performance window first.

The Device menu includes the App title plus installation/connection alias so same-name Apps remain
distinguishable. Rows that still exist for recent-disconnect presentation but cannot compile an
exact analysis target are disabled and do not count as available fallback choices. With no eligible
Device, the window shows a compact Device empty state instead of empty cards, charts, and
availability rows.

The dashboard is a projection of ordinary Events. It does not add another network protocol,
database, sampler, acknowledgement path, or persistence format. The bounded current memory Session
is authoritative. The dashboard can be rebuilt from that input and never persists derived buckets.

## Ranges and time

The range picker provides **1 min**, **5 min**, **15 min**, and **Session**. Five minutes is the
default. A fixed range ends at the frozen analysis anchor and is clipped to the selected device
session start. Session begins at that start. Both ends are inclusive.

NearWire orders samples by Viewer monotonic receive time. The Viewer wall receive time supplies
human-readable labels. App `sampledAt` values remain available in the raw Event, but they never
reorder charts or merge timelines. This avoids clock skew and wall-clock changes on the phone.

A current range freezes the bounded memory projection. An Event accepted after that freeze belongs
to the next refresh. Imported offline Sessions use their frozen Event times and never compare an old
monotonic clock with the current Mac uptime.

## Current cards and availability

The **Current** section has 12 cards: estimated and maximum frame rate, CPU, memory footprint,
battery level and state, thermal state, Low Power Mode, App-to-Viewer queue depth, dropped Events,
and App-to-Viewer and Viewer-to-App byte rates.

Cards use the latest raw performance Event at or before the range anchor, looking back at most 180
seconds even when that extends before the chart range. A valid snapshot is fresh for the smaller of
180 seconds and the larger of three sample intervals or three seconds. An unreadable or invalid
snapshot uses three seconds. Reaching the deadline is stale: all cards show **No recent sample**.
Current cards expire from one exact deadline callback. Imported offline Session cards are evaluated
once against their frozen anchor and do not run a timer.

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

## Open the raw Event

**Open Raw Event** uses the selected metric's representative journal key at action time. It asks
Event Explorer to resolve that exact key from the current memory Session, opens or focuses the main
Viewer with Inspector visible, and then safely resumes Performance. Main-window focus changes only
after a successful reveal. Evicted, stale, or unavailable content leaves focus in Performance and
produces fixed guidance there. NearWire never opens a neighboring Event, passes copied JSON between
controllers, or exports a derived bucket. If the Event Timeline is paused, the exact retained
detail can open without changing its visible Timeline rows or Pause state.

## Refresh, pause, and cleanup

At most one projection scan runs, with at most one dirty successor. Repeated change notifications
do not create one task per Event or continuously cancel useful work. Current refresh is capped at
ten publications per second and one per main run-loop turn.

**Pause** freezes the complete Performance presentation. It does not pause network receive, live
admission, memory retention, or session flow control. While paused, NearWire keeps only bounded dirty
state. **Resume** performs one fresh projection. Changing the Performance Device or range, replacing
the runtime, importing a Session, or closing Performance invalidates and joins prior Performance work
before a successor can own its projection. Performance cleanup clears
projection work, deadline receipts, cache, cards, buckets, gaps, invalid details, crosshair,
tooltip, and raw-resolution work. Closing the Performance window also clears Pause so reopening
starts one fresh projection while preserving the valid Device and range controls. Late results from
an old generation are rejected.

When the requested range starts before retained memory, the dashboard shows **Memory window only**.
The leading range remains disconnected, bounded memory-window overflow is disclosed, and NearWire
does not interpolate missing samples or query a database.

## Deterministic bounds

The projection reduces the bounded memory Session while keeping resident and per-turn work bounded:

| Resource | Maximum |
| --- | ---: |
| Buckets | 512 |
| Completed cached ranges for the selected Session/Device | 4 |
| Detailed gaps | 128 |
| Invalid-snapshot details | 128 |
| Charts | 6 |
| Total chart marks | 12,288 |
| Accessibility bucket summaries per chart | 64 |
| Raw Event content decoded per Event | 65,536 bytes |
| Events decoded per cooperative turn | 64 |
| Completed projection result | 8 MiB |
| Shared derived-state accounting ledger | 16 MiB |
| Deterministic peak including the derived-state ledger, live slice, and decoder | 21,336,064 bytes |

Gap classification and Event decoding use bounded cooperative work. The byte accounting is a
deterministic ownership contract, not a claim about the Swift allocator's exact heap footprint.
Limit exhaustion publishes fixed guidance and never a partial result marked complete.

## Privacy and exclusions

Projection state contains aggregates, bounded diagnostics, and journal identities, not raw JSON.
Content-bearing work is generation-bound and prepared off the main actor. Reflection and debug
descriptions of projections, chart points, tooltips, and model diagnostics are redacted. The
dashboard adds no logging, analytics, clipboard, drag, share, file export, restoration, or derived
history. Raw Event content remains governed by Event Explorer's privacy and JSON-export rules.

V1 intentionally excludes multi-device or reconnect-spanning overlays, custom formulas, alerts,
thresholds, annotations, MetricKit payloads, interpolation, third-party charts, derived-data export,
dashboard persistence, a performance-specific transport, and changes to SDK
sampling.

Dashboard development and CI may use unsigned Viewer builds. That validates compilation, behavior,
resource contracts, and cleanup but does not validate the login-Keychain cross-update boundary.
Before release, run the stable-signer update gate documented in
[Viewer-Foundation.md](Viewer-Foundation.md). In the current Goal workflow that configured signed
gate is intentionally deferred to final release hardening; unsigned evidence must not claim it.
