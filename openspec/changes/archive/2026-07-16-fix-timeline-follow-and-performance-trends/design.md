# Design

## Timeline follow intent

On macOS 15 and later, the Timeline observes `ScrollGeometry` rather than relying only on a lazy tail row's frame. The observation retains visible maximum Y and content height. A same-height movement away from the bottom disables following immediately. When content height grows while the prior state was at the bottom and the visible position did not move upward, following remains latched long enough to reveal the successor Event.

The existing tail-marker frame measurement remains as the macOS 13/14 fallback. Tail disappearance may clear stale following, but lazy-row appearance alone never promotes the fallback to the bottom. A small settled-row latch preserves a previously true follow intent while newly appended content temporarily moves the tail marker offscreen; an already false user intent remains false.

Programmatic Jump to Latest remains nonanimated and reports the completed bottom state. A normal Event publication never changes a false follow intent to true.

## Performance continuity

An empty aggregation bucket means no sample landed in that display interval; it is not by itself evidence of a data discontinuity. Chart preparation therefore carries the current segment across ordinary empty buckets. An empty bucket carrying an explicit discontinuity latches a pending break for the next measured point. A measured bucket also starts a new segment when it is explicitly discontinuous or immediately follows an explicitly discontinuous measured bucket.

The existing continuity tracker and gap projection remain authoritative. They already mark buckets for sample-horizon gaps, invalid/unavailable transitions, placed gaps, and conservative unplaced gaps.

## Performance appearance

Each metric uses:

- a translucent min/max `AreaMark` band;
- a stronger monotone average `LineMark`;
- a small point marker for ordinary samples and a larger marker for a single-sample series.

The number of marks remains three per measured point, so the existing 1,200-point and 12,288-mark bounds do not change. Projection remains off the MainActor and SwiftUI consumes immutable prepared series.

## Verification

- Exercise scroll-geometry state transitions for user movement, content growth, returning to bottom, and stale reports.
- Host a real Timeline, scroll away from the bottom, publish another Event, and confirm the reading position does not jump.
- Verify sparse samples share a line segment unless an explicit discontinuity is present.
- Render a multi-sample Performance dashboard and inspect the continuous line and envelope band.
- Run Viewer tests, build, strict OpenSpec validation, and independent review rounds.
