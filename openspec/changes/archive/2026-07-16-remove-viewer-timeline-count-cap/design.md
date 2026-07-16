# Design

## Context

The current memory Session has two independent retention limits: 512 Events and 32 MiB of deterministic accounted Event data. Every retained Event already includes a fixed 32 KiB accounting reserve, so the byte budget itself implies a finite maximum number of resident slots. The Explorer then takes a 512-row suffix even though the snapshot cannot currently exceed that count.

## Goals and Non-Goals

Goals:

- Remove the arbitrary 512-Event product limit from retention, import, evaluation, and Timeline publication.
- Preserve deterministic memory safety and constant-work callback ingress.
- Preserve oldest-first eviction, exact-key duplicate tracking, gaps, filters, selection, Pause, and tail-follow behavior.

Non-goals:

- Provide unlimited process memory or retain history after the 32 MiB memory window is exhausted.
- Change ingress, protocol queue, service-turn, predicate, JSON traversal, or time limits.
- Add persistence, pagination, or a user-configurable memory budget.

## Decisions

### Accounted bytes are the retention authority

The deque evicts only while the incoming Event would exceed the 32 MiB accounted-byte budget. It does not evict merely because the number of Events reaches 512.

### Fixed storage is derived, not a product limit

The deque and bounded marker storage require finite allocation. Their defensive slot capacity is derived as `retainedBytes / fixedEntryOverheadBytes`. With the existing values this is 1,024 slots. Since every Event is charged at least the fixed overhead, no byte-valid snapshot can require more slots. Code treats this value as an implementation capacity implied by the memory budget, not as a second retention policy.

Lock-side authority and pending per-key disposition/conflict state can additionally cover the 64 Events already admitted by the fixed ingress while the projection executor is blocked. Their bound is therefore the byte-derived 1,024 retained slots plus the 64 ingress slots. This preserves metadata for every accepted pending Event without permitting unbounded growth.

### Timeline publishes the complete retained snapshot

The Explorer no longer applies `suffix(512)`. A completed filter evaluation publishes every matching row from the immutable retained snapshot in receive order. Stable identities and viewport-based tail following remain unchanged, so an operator reading older Events is not moved when new Events arrive.

### Import and evaluation use the same derived safety bound

Import remains bounded by 32 MiB and the finite file budget. A defensive count check uses the byte-derived slot capacity only to reject structurally impossible carriers before materialization. Evaluation accepts the same complete byte-valid snapshot and retains its existing predicate, JSON-node, cancellation, and 100 ms work limits.

## Risks and Mitigations

- More rows can increase evaluation and SwiftUI work. The maximum grows only from 512 to the byte-implied 1,024 slots, evaluation remains detached and bounded, and SwiftUI retains stable row identities.
- Removing the count condition could exhaust deque slots if accounting diverges. Every insertion validates deterministic bytes plus fixed overhead, and exact-boundary tests prove slot capacity is sufficient for all byte-valid Events.
- Users may interpret “no count cap” as unlimited history. The UI remains a memory-window viewer; gap diagnostics continue to report oldest-first eviction when accounted bytes are exhausted.

## Verification

- Retain and display more than 512 minimum-size Events without a count-triggered gap.
- Evict oldest Events and report a gap when accounted bytes exceed 32 MiB.
- Import and filter a snapshot above 512 Events within the byte budget.
- Confirm manual upward scrolling still prevents automatic tail following.
- Run the Viewer test suites, strict-concurrency compilation, build, strict OpenSpec validation, and independent reviews.
