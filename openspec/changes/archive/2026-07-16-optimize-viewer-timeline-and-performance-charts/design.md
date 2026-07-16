## Context

An Event moves through normal dispositions such as `buffered`, `transportAdmitted`, and `consumerAccepted`. Timeline presentation currently hides only the final accepted value, so ordinary admission briefly appears as a diagnostic badge.

Performance projection already decodes and aggregates Events in a detached task, but the published result contains only buckets and cards. SwiftUI then constructs all six chart projections during body evaluation. For every measured point, continuity discovery scans backward across earlier buckets. A dense series therefore performs quadratic work on the MainActor and repeats that work whenever unrelated view state invalidates the body. The existing `RectangleMark` has zero height when minimum equals maximum and `LineMark` does not draw a useful segment for one sample, so isolated measurements can be invisible.

## Goals and Non-Goals

Goals:

- Keep normal Event admission invisible in Timeline rows while preserving exceptional outcomes.
- Move chart projection and continuity preparation into the existing off-main projection task.
- Make chart preparation linear in bucket count per metric and chart rendering proportional to measured points.
- Keep isolated and sparse measurements visibly represented.
- Reduce live chart mark volume without weakening deterministic aggregation or uncertainty semantics.

Non-goals:

- Change Event admission, flow control, filtering, selection, or retention.
- Change Performance Event schemas, cards, range picker choices, tooltip semantics, or raw-Event reveal.
- Add chart configuration, persistence, animation, or a new dependency.

## Decisions

### Timeline distinguishes normal progress from diagnostics

`buffered`, `transportAdmitted`, and `consumerAccepted` are normal stages of one successful receive pipeline. Timeline presentation omits all three. Terminal, expired, overflow-displaced, gap, drop, and conflict information remains visible because it changes how an operator interprets the Event.

### Dashboard aggregation uses at most 120 display buckets

The dashboard range is reduced into at most 120 aligned buckets. This remains below the established global ceiling of 512 and continues to preserve minimum, average, maximum, counts, representative journal identity, availability, and discontinuities. A five-minute range therefore produces approximately one chart point every 2.5 seconds at maximum density rather than always creating 512 bucket slots. The existing 512-bucket validation limit remains a defensive carrier boundary.

### Chart projections own prepared measured points

Each immutable chart projection stores its bounded points grouped by metric. Preparation walks each metric's buckets once, carries the current segment start forward, validates accumulators, and appends only measured buckets. This removes per-point backward scans and prevents SwiftUI from traversing empty bucket slots.

The projection is constructed in `ViewerPerformanceProjectionSession.finalize`, which already runs in the controller's detached worker. Freshness-only publication updates reuse the same chart projections because they change cards, not aggregated buckets.

### Every measurement has an explicit point mark

Charts retain min/max envelope and average line marks and add a small `PointMark` for each prepared measurement. The point is visible when a series contains one sample or when minimum, average, and maximum are equal. Discontinuity still divides line series using the precomputed segment identifier.

### SwiftUI remains a presentation layer

The Performance view reads prepared projections from the model and iterates the immutable point arrays. Chart and metric identifiers remain semantic, and data updates continue to disable implicit animation. The view performs formatting and mark declaration only; it does not recompute aggregation or continuity.

## Risks and Mitigations

- Fewer buckets reduce temporal resolution for long ranges. The 120-bucket bound is still denser than the expected visual width, retains envelopes, and does not discard raw Events from the in-memory Session.
- Prepared points add derived memory. They are bounded to ten metrics times 120 buckets and use a separate deterministic publication-layer budget of at most 157,696 bytes; they are not charged to the completed-result cache ledger. This bounded allocation replaces repeated transient allocations during rendering.
- Adding point marks increases marks per measured bucket. The lower dashboard bucket bound keeps the worst case below the existing 12,288 global mark ceiling.
- Hiding admission states could conceal failures if classification is too broad. Only the three known successful pipeline stages are hidden; exceptional dispositions and separate diagnostics remain visible.

## Verification

- Focused Timeline presentation tests cover all normal admission stages and an exceptional disposition.
- Chart projection tests cover isolated-sample visibility, sparse/discontinuous segmentation, linear prepared point collections, and the 120-bucket dashboard bound.
- Controller/model tests verify chart projections are published and freshness updates preserve them.
- The full Viewer test suite, strict-concurrency checks, Viewer build, and strict OpenSpec validation provide final evidence.
