# Pre-Implementation Architecture and API Review

## Verdict

**Changes required before implementation.** The proposed Viewer-only module split, Core SPI reuse,
raw-Event authority, shared live projection, identity-only Explorer handoff, and macOS 13/Swift 5
baseline are sound. Four artifact issues remain actionable because they leave memory bounds, gap
ordering, one required UI outcome, or Store traversal ownership undefined.

## Scope Reviewed

- The complete proposal, design, task list, and all four capability deltas for
  `viewer-performance-dashboard`.
- The canonical performance schema, Event Explorer, local Store/search, and multi-device flow
  specifications.
- Existing Core `PerformanceSnapshot` SPI, Viewer source/device/Event identities, live projection,
  Store gateway/query arbiter, SQLite schema/indexes, and runtime cleanup ownership.
- Strict OpenSpec validation and whitespace validation for the active change.

## Findings

### P1

1. **[P1] (confidence: 10/10) `specs/viewer-local-store-search/spec.md:8-11`, `design.md:60-66` - The 512-carrier page has no aggregate content-byte bound.**

   Each carrier is required to contain canonical content bytes, while the 64-KiB rule is only a
   typed-decode rejection threshold. NearWire can retain Events larger than 64 KiB, so a page can
   materialize many oversized blobs before the projection classifies them as invalid. The page-row,
   VM, and time limits do not bound the memory already returned by SQLite. This contradicts the
   design's constant-bounded projection goal and makes malicious reserved Events an avoidable memory
   amplification path.

   **Required artifact fix:** Add an exact per-turn/page content-byte budget and define an
   oversize-row carrier that includes identity, ordering metadata, and content length but does not
   materialize the blob. Require SQL/Store work to fetch canonical bytes only for rows at or below
   64 KiB, return a continuation at the last visited key, and add boundary/aggregate-byte tests to
   tasks 2.1, 2.2, and 6.1/6.2.

2. **[P1] (confidence: 10/10) `specs/viewer-performance-dashboard/spec.md:38-42,106-111`, `design.md:126-133,184-191` - Historical Store gaps cannot be placed in the required monotonic chart order under the stated no-migration design.**

   Dashboard samples and buckets use Viewer monotonic receive time, and Viewer wall time is labels
   only. Existing schema-2 `GapVersions` and `ViewerGapRow` retain only first/last Viewer wall
   milliseconds, not monotonic bounds. The new Store delta defines only a raw performance-Event
   traversal and does not define a performance gap traversal or conservative fallback. Therefore an
   implementation cannot determine where a historical Store gap splits a monotonic series without
   using wall time as ordering authority, inventing placement, or changing the schema.

   **Required artifact fix:** Choose and specify one complete contract before implementation:
   either add monotonic gap bounds through a migration, or keep schema 2 and define a conservative
   historical-gap presentation that never places a gap by wall time and never draws a line whose
   continuity cannot be proven. Update the Store delta, design, tasks, and tests for the chosen
   behavior.

3. **[P1] (confidence: 10/10) `specs/viewer-performance-dashboard/spec.md:44-47,70-75,113-117`, `tasks.md:30-32` - The GPU-unavailable scenario requires a UI result that no declared card, chart, or task implements.**

   The required cards and ten-metric chart inventory omit GPU, consistent with the Core schema's
   lack of numeric GPU utilization. The scenario nevertheless requires GPU to render as
   `Unsupported`. There is no specified GPU status surface, and unknown unavailable keys are
   otherwise raw-only. The implementation and test plan therefore cannot satisfy the scenario
   deterministically.

   **Required artifact fix:** Replace GPU in this scenario with an in-scope displayed metric whose
   value is absent and whose known unavailable record is present, or explicitly add a bounded GPU
   availability-only card plus matching design/task/test requirements. Do not add a fabricated
   numeric GPU metric.

### P2

4. **[P2] (confidence: 9/10) `design.md:53-70,147-164`, `specs/viewer-event-explorer-control/spec.md:5-16`, `tasks.md:9-10,25-26` - Event and Performance traversal arbitration is not defined for mode switches or raw reveal.**

   The existing Store gateway has one query arbiter whose current state owns one Event traversal.
   The change adds a specialized performance traversal to that same owner while preserving the
   Event Explorer controller. The artifacts do not say whether the two traversals may coexist, which
   mode releases the finite lease, or which operation wins when `Open Source Event` switches from an
   active performance scan to an Explorer exact reload. Reusing the existing traversal slot would
   clobber Explorer state; silently adding a second retained slot changes the canonical single-query
   ownership and aggregate lease bounds.

   **Required artifact fix:** Define named ownership and transition ordering. The simplest contract
   is that only the visible Events or Performance mode owns an active Store traversal: invalidate
   the departing presentation generation, cancel/join and release its exact lease, then admit the
   successor traversal. Specify the same sequence for identity-only raw reveal and test rapid mode,
   source, range, Store-generation, and reveal races. If two traversal slots are intended instead,
   state their independent identities, aggregate lease/operation bounds, and non-clobbering cleanup
   rules explicitly.

## Confirmed Architecture Decisions

- Core owns the platform-neutral V1 schema, and Viewer can decode it through the existing
  `NearWireInternal` SPI without a public SDK, wire, SPM, or CocoaPods API change.
- Raw durable Events and the existing bounded immutable live snapshot can remain the only sources of
  truth. A separate live projection, Store owner, database, or derived persistence layer is neither
  necessary nor permitted.
- Exact source/device identity is available without authentication claims: current runtime logical
  ID plus connection ID for live scope, or positive recording/device-session row IDs under a Store
  generation for durable scope. Exact durable row identity and transient `ViewerEventJournalKey`
  are sufficient for an identity-only Explorer reveal once finding 4 defines transition ordering.
- The existing `EventTimelineByDevice(recordingID, deviceSessionID, viewerMonotonicNs, rowID)` index
  supports a bounded candidate scan with post-filtering by exact Event type, so performance samples
  themselves do not require a schema migration. This conclusion does not resolve finding 2 for gap
  placement.
- System Swift Charts is available on macOS 13, the Viewer already links the root `NearWireCore`
  product, and the project is configured for Swift 5 language mode with complete concurrency
  checking. No third-party dependency is needed.
- Runtime cleanup can remain single-owner by joining the dashboard controller's sealed cleanup task
  into the existing application presentation cleanup and runtime receipt, without moving protocol or
  live-window ownership.

## Validation

- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict` - passed.
- `env DO_NOT_TRACK=1 openspec show viewer-performance-dashboard --json` - parsed all ten deltas.
- `git diff --check -- openspec/changes/viewer-performance-dashboard` - passed before this report.

**Unresolved findings: 4**
