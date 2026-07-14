# Security, Performance, and Documentation Artifact Pre-Review

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Changes required before implementation.**

The artifacts establish the correct high-level trust boundary: raw Events remain authoritative;
derived performance state is memory-only and non-exportable; received metrics stay out of logs,
analytics, preferences, restoration, safe rows, clipboard, drag, and share surfaces; Swift Charts is
the macOS system framework rather than a package dependency; and configured signing plus embedded
entitlement inspection remains explicitly deferred to Goal-level `release-hardening`.

Five actionable gaps remain in the normative malformed-input, raw-page memory, retained-state,
source-cache cleanup, and timing-evidence contracts. These gaps are implementation-shaping rather
than editorial and should be resolved in the artifacts before task 1.1 closes.

## High-severity findings

### 1. Conflicting and duplicate availability records have no closed typed-projection rule

**[HIGH] (confidence: 10/10)**

`specs/viewer-performance-dashboard/spec.md:94-111` defines present, unavailable, absent, invalid,
stale, and zero states, but does not define the result when a known metric is both present and listed
as unavailable or when the same unavailable metric key occurs more than once with different reasons.
The current Core decoder accepts both shapes: `PerformanceSnapshot` stores the decoded
`[UnavailablePerformanceMetric]` without uniqueness or present-value conflict validation
(`Core/Sources/NearWireCore/Builtins/Performance/PerformanceSnapshot.swift:199-224, 274-281`). A
malicious or independently constructed reserved Event can therefore reach the Viewer with
contradictory but Core-decodable claims. Choosing first, last, value, or unavailable in implementation
would produce an undocumented trust-boundary decision and can make cards and charts disagree.

**Required artifact change:** Define one deterministic rule for duplicate known unavailable keys and
present-plus-unavailable conflicts. The safest contract is to classify the typed snapshot as invalid,
retain only its raw Event identity for Explorer inspection, and publish no metric from that snapshot.
Extend task 6.2 to cover identical duplicates, conflicting duplicate reasons, present-plus-unavailable,
and unknown raw-only keys.

### 2. A 512-row raw page has no aggregate byte bound and materializes content before oversize rejection

**[HIGH] (confidence: 10/10)**

`specs/viewer-local-store-search/spec.md:5-17` permits 512 carriers per page and requires every carrier
to contain canonical content bytes, while `specs/viewer-performance-dashboard/spec.md:11-17` rejects a
typed snapshot only after its content exceeds 64 KiB. There is no aggregate page/carrier byte limit and
no rule allowing the Store to classify an oversized row from its SQLite byte length without copying the
full content. Existing Core configuration permits encoded content up to 16 MiB
(`Core/Sources/NearWireCore/Event/EventValidationLimits.swift:92-98`), so the stated row limit alone can
authorize up to 8 GiB of canonical content in one returned page. Even the 256-KiB default permits a
128-MiB page. The 16-MiB projection-cache limit does not cover this traversal scratch state.

**Required artifact change:** Add checked aggregate bytes to every traversal turn/page and define how
progress is made at the boundary. Oversized typed content should be identified from bounded metadata
such as SQLite byte length and returned as identity plus a content-free invalid classification, leaving
the complete bytes in the raw Event store for Explorer inspection. Canonical bytes at or below 64 KiB
must be streamed or paged under an explicit total byte cap and released after reduction. Extend tasks
6.1 and 6.2 with exact 64-KiB/64-KiB-plus-one cases, 512 maximum-size rows, aggregate-byte exhaustion,
cancellation, and proof that the full oversized JSON is not copied into the typed traversal result.

### 3. Categorical transitions, gaps, invalid diagnostics, and chart marks are called bounded without numeric bounds

**[HIGH] (confidence: 9/10)**

`specs/viewer-performance-dashboard/spec.md:61-80` gives numeric buckets and cache bytes exact limits
but leaves categorical transitions and gaps merely "bounded." Lines 106-110 can create discontinuities
for explicit gaps and each invalid snapshot, and lines 174-190 retain invalid/unavailable diagnostics
and accessibility/chart state without a total diagnostic, transition, or rendered-mark count. The design
repeats the same undefined bound at `design.md:82-88`. An arbitrarily long Current Session containing
alternating categorical values, explicit gaps, or malformed snapshots can therefore append state per
Event despite the 512 numeric-bucket limit. The 64-summary accessibility cap does not bound non-bucket
diagnostics or the Swift Charts mark tree. Tasks 6.3 through 6.7 do not require a pathological transition,
gap, and invalid-snapshot retention count.

**Required artifact change:** Define exact per-bucket and global count/byte limits for categorical
transitions, gap intervals, invalid/unavailable diagnostics, tooltip values, chart marks, and accessible
summaries. Specify deterministic coalescing/eviction and one saturating loss indicator when detail exceeds
those limits; no Event-sized side list may remain. Add a 100,000-sample case that alternates every
categorical state and injects a gap or invalid snapshot per sample, then gate exact retained objects,
bytes, chart marks, accessibility summaries, and cleanup.

### 4. The four-range cache is not normatively global to one current source and source/device replacement does not clear it

**[HIGH] (confidence: 9/10)**

The design says the projection owner is cleared on source replacement (`design.md:38-47`) and that one
generation has up to four completed ranges for the exact same source (`design.md:82-88`). The normative
spec instead says "The exact source MAY cache at most four" (`specs/viewer-performance-dashboard/spec.md:77-80`),
which permits an implementation to keep four entries per previously visited source. Source/device change
only invalidates the predecessor before cancellation (`specs/viewer-performance-dashboard/spec.md:125-141`),
while the exhaustive clear list at lines 186-190 covers runtime end, window close, listener failure,
TLS/full reset, Store replacement, and deinitialization but omits ordinary source and device replacement.
Repeated browsing can therefore retain prior-device content and grow completed caches beyond one global
16-MiB owner even though stale publication is generation-blocked.

**Required artifact change:** State that one dashboard controller owns one globally bounded cache for only
the currently selected source/device, with four ranges and 16 MiB total across active reduction,
completed entries, claimed delivery, and presented values. Source or device replacement must seal
admission, invalidate, cancel and join old work, clear every old cache/content-bearing delivery/model
value, and only then admit successor work. Range changes may reuse completed entries only for the same
unchanged source/device. Add repeated source/device-switch tests that prove constant retained entries,
bytes, identities, and zero predecessor content after each switch.

## Medium-severity finding

### 5. The normative 50-ms turn deadline is not separated from host timing evidence

**[MEDIUM] (confidence: 9/10)**

`specs/viewer-local-store-search/spec.md:13-17` and
`specs/viewer-performance-dashboard/spec.md:125-133` make 50 ms a normative traversal-turn limit.
Task 6.1 says to gate every time bound, while task 6.7 correctly says host timing is diagnostic only.
The artifacts do not state that the 50-ms decision uses an injected monotonic logical deadline or that
tests advance that clock deterministically. A test can therefore accidentally gate wall-clock duration,
or the implementation can satisfy only row/VM limits while treating the elapsed deadline as benchmark
context. The same evidence text should also distinguish deterministic projection-byte accounting from
observed Swift process heap.

**Required artifact change:** Define an injected monotonic deadline checked at deterministic row/VM/decode
checkpoints, require fake-clock boundary tests for 49-ms/50-ms/exceeded decisions, and retain row, VM,
page, bucket, cache, and byte counts as normative structural gates. Record real elapsed time and process
heap only as paired host diagnostics, with no product guarantee inferred from those observations.

## Verified controls with no finding

- Raw durable and bounded transient Events remain the only authoritative inputs; derived buckets are
  rebuildable, memory-only, non-exportable, and trace back by identity rather than copied content.
- Oversized or malformed snapshots remain available through ordinary raw Event inspection and cannot
  fabricate typed values once findings 1 through 3 are corrected.
- Performance content is explicitly excluded from logs, analytics, preferences, restoration, safe rows,
  generic reflection, clipboard, drag, and share surfaces; raw JSON remains governed by the existing
  Event Explorer privacy/export boundary.
- Lifecycle cleanup seals, cancels, joins, and clears content for runtime/window/listener/TLS/Store/deinit
  paths; finding 4 is limited to the omitted ordinary source/device replacement path.
- Accessibility has deterministic labels, non-color states, keyboard navigation, and a 64-summary
  per-chart cap; finding 3 concerns the missing total transition/diagnostic/mark bounds around it.
- Swift Charts is identified as the macOS 13 system framework, not a package dependency. The change adds
  no root-package, CocoaPods, third-party runtime, entitlement, or schema migration.
- English operator documentation is required to cover authority, ranges, units, gaps, unavailable/stale/
  invalid states, privacy, cleanup, exclusions, and signing deferral. Configured signing and embedded
  entitlement inspection are not claimed by this change and remain deferred to `release-hardening`.
- Task 6.7 correctly prohibits a shell harness and requires host timing to remain diagnostic; finding 5
  asks the normative 50-ms gate to be made unambiguously deterministic.
- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive` passes,
  and OpenSpec parses ten deltas across the four capability specifications.

## Unresolved finding count

**5**
