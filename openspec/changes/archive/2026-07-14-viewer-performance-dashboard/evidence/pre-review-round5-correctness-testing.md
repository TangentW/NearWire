# Correctness and Testing Artifact Review — Round 5

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Approved for implementation from the correctness/testing dimension.** This fresh artifact-only
review found no unresolved correctness or testability issue. I independently reread the current
proposal, design, tasks, all five delta specifications, prior review/remediation evidence, and
`pre-review-remediation-round4.md`. Both Round 4 findings now have distinct state, closed boundary
behavior, and mutation-sensitive planned tests. Previously closed traversal, projection, lifecycle,
resource, availability, traceability, and privacy contracts remain coherent after the remediation.

Configured signing and inspection of entitlements embedded in a signed product remain deferred by
product-owner decision to Goal-level `release-hardening`. That deferred gate is not a finding in this
review.

## Round 4 Finding Status

### R4-CT-1 — Closed: current and historical freshness use distinct clock domains

The current artifacts now make the distinction normative:

- Only a current-source result owns an absolute Viewer-monotonic deadline and deadline revision.
  Claim and MainActor apply both validate source generation, latest journal key, deadline, revision,
  and injected current uptime. Equality is stale, only a strictly future deadline is scheduled, a
  callback fires at most once, and an elapsed result cannot restore fresh cards or re-arm itself
  (`specs/viewer-performance-dashboard/spec.md:135-152,242-249,275-279`;
  `design.md:147-163,228-235`).
- Historical cards compare the latest Event with the frozen historical upper in the same recording
  monotonic domain. They never compare with current uptime, never schedule a callback, do not age
  while paused, and invalidate/join their receipt before a current-source successor uses current
  uptime (`specs/viewer-performance-dashboard/spec.md:154-159,281-285`;
  `design.md:165-170,230-235`).
- Tasks 3.5, 4.1, 4.2, 6.4, and 6.5 require distinct receipt types/paths, historical anchors below,
  equal to, and above current uptime, simulated uptime reset, Pause, current/historical switching,
  claim/apply barriers, one current wake, zero historical wakes, and zero predecessor state.

These rules produce the same historical card result for the same frozen recording regardless of the
current process uptime. They also preserve the Round 3 guarantee that a current late delivery cannot
reverse stale to fresh.

### R4-CT-2 — Closed: Store separates pagination from applicable overflow

The Store wrapper now carries three independent values inside the fixed 512-byte charge:

- generic `hasMoreRows` for pagination;
- a saturating performance-or-uncertain count; and
- `hasMoreApplicableGaps` for applicable evidence beyond the retained projection detail.

Store normalizes the complete frozen matching metadata scope before deciding applicable overflow,
under cancellation, accepted-plan, 2,000,000-VM-step, and injected-250-ms gates. Hidden irrelevant-
only rows set only generic pagination. A hidden performance/uncertain row sets applicable overflow.
Budget exhaustion also sets applicable overflow and cannot claim complete classification
(`specs/viewer-local-store-search/spec.md:28-48,72-76`;
`specs/viewer-performance-dashboard/spec.md:165-196,221-225`).

The two formerly indistinguishable 129-row scopes now have different receipts even when both retain
the same 128 irrelevant carriers. The irrelevant-only tail remains connected; a hidden applicable
tail is Unplaced. Live uses the same applicable count/overflow concept, and the reducer separately
checks more than 128 combined applicable details. Tasks 2.2, 2.4, 2.5, 3.4, 6.1, 6.4, and 6.5 cover
the complete mapping table, classification-budget mutation, identical-retained paired fixtures,
127/128/129 Store/live/combined boundaries, and conservative unknown behavior.

## Complete Boundary Recheck

- **Traversal:** The opaque last-examined continuation advances for matching and nonmatching rows.
  Candidate, carrier, content, VM, and injected-time equality rules distinguish pre-row byte stops,
  post-row VM/time stops, zero-match progress, terminal pre-first-row exhaustion, cancellation, and
  Store-generation rejection without skip, duplicate, or livelock.
- **Freeze and ordering:** Live-first drained-ingress freeze, later Store Event/gap uppers, anchor
  filtering, journal-key deduplication, locator-only durable replacement, canonical equal-time order,
  and barrier-controlled commit permutations provide exactly-once contribution.
- **Ranges and cache:** Current, ended, interrupted, and empty anchors; checked inclusive arithmetic;
  exact bucket edges; complete cache identity; canonical comparators; LRU touch/fifth insertion; and
  mandatory source/device clearing remain deterministic.
- **Aggregation and uncertainty:** Ten metric-specific accumulators, categorical summaries,
  availability precedence, invalid/missing metric breaks, wall-envelope placement, interval-less and
  unknown Unplaced behavior, combined applicable overflow, and metric-specific raw representatives do
  not interpolate or fabricate values.
- **Refresh and lifecycle:** One running scan plus one dirty successor, latest-only MainActor delivery,
  Pause rules, current-only deadline ownership, historical no-wake behavior, mode handoff, Store
  unavailable/recovery, generation invalidation, claimed-delivery join, and cleanup prevent stale or
  predecessor publication.
- **Resource accounting:** The maximum structural result independently recalculates to 1,103,104
  deterministic bytes. The shared ledger, Store Event page, live slice, Store gap page, and decoder
  independently sum to the stated 25,805,312-byte peak. New Store wrapper scalars remain inside the
  existing fixed 512-byte wrapper, and complete-scope classification requires no retained Event-sized
  side list.
- **Coverage:** Tasks 6.1 through 6.7 contain proportionate unit, integration, adversarial,
  concurrency, accounting, and 100,000-sample cases with injected logical seams. Host timing and heap
  remain diagnostic only; no shell test harness is introduced.

## Validation

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

env DO_NOT_TRACK=1 openspec show viewer-performance-dashboard --json --deltas-only
exit 0; deltaCount: 11

git diff --check -- openspec/changes/viewer-performance-dashboard
exit 0, no output

deterministic maximum-result arithmetic
1,103,104 bytes

deterministic peak arithmetic
25,805,312 bytes
```

This review modified no production/test source or other artifact and wrote only this report.

## Findings

No P0, P1, or P2 correctness/testing findings.

## Unresolved Finding Count

**0**
