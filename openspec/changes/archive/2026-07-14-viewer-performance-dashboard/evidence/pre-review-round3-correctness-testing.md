# Correctness and Testing Artifact Review — Round 3

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Changes are still required before implementation.** I independently reread the current proposal,
design, tasks, all five delta specifications, the Round 2 correctness report, and the Round 2
remediation report. The three Round 2 findings are substantively resolved: the accounting constants
now form an independent oracle, card-state precedence is explicit, and journal/cache comparators are
canonical. Two newly exposed boundary contracts remain undefined: deadline ordering against a late
scan publication, and normalized/live-gap applicability and overflow evidence.

Configured signing and inspection of entitlements embedded in a signed product remain deferred by
product-owner decision to Goal-level `release-hardening`. That deferred gate is not a finding in this
review.

## Findings

### R3-CT-1 — P1 (confidence: 10/10): a late scan publication can reverse a freshness deadline

The revised card rule correctly evaluates freshness before typed state, uses a three-second horizon
for an unreadable header, treats equality as stale, and specifies no deadline when no Event exists
(`specs/viewer-performance-dashboard/spec.md:135-142`; `design.md:147-153`). Separately, one running
scan is allowed to finish and publish while refresh work becomes dirty, and one replaceable deadline
marks the presentation stale (`specs/viewer-performance-dashboard/spec.md:183-187`;
`design.md:185-189`). The artifacts do not order those two producers.

A deterministic race remains:

1. A scan freezes while its latest one-second sample is still fresh and then blocks.
2. The absolute three-second deadline fires and the current cards become `No recent sample`.
3. The still-current scan completes or a previously claimed MainActor delivery applies after the
   deadline.

The scan is expressly permitted to publish, but the artifacts do not require publication-time clock
revalidation or a card/deadline revision comparison. It may therefore restore the pre-deadline fresh
card. If that result re-arms its already elapsed deadline, an immediate wake loop is also possible;
the specification says only that the deadline is replaceable and not a poll, not that stale/past
deadlines are never scheduled.

Tasks 6.4 and 6.5 cover deadline equality, freshness wake, running-plus-dirty work, and claimed
delivery, but not their barrier-controlled cross-product. A mutation that applies an older fresh
result after the deadline can therefore pass every planned assertion.

**Required artifact remediation:** Give every card result an absolute deadline and latest-Event
identity/revision. At MainActor claim and apply, compare the injected clock and reject or restate any
expired card as `No recent sample`; a deadline callback must validate the same source generation,
Event identity, and deadline revision. Arm only a strictly future deadline, cancel/no-op an elapsed
one, and define behavior while paused. Add barriers for deadline before/after scan completion,
delivery claim, delivery apply, Pause/Resume, and source/runtime replacement, including proof of one
wake, no freshness reversal, and no immediate re-arm loop.

### R3-CT-2 — P1 (confidence: 9/10): normalized gap applicability and live-gap overflow have no closed input contract

The Store and dashboard now require a fixed 256-byte normalized gap carrier with a “closed safe kind”
and “applicability,” while excluding variable namespace, reason, and direction strings
(`specs/viewer-local-store-search/spec.md:28-34`;
`specs/viewer-performance-dashboard/spec.md:148-155`; `design.md:159-167`). No artifact enumerates the
closed kinds or maps raw Store/live direction, reason, scope, and unknown values into applicability.
An implementation can therefore ignore a Viewer-to-App/control-only gap, suppress the chart for it,
or classify an unknown gap differently, with each choice fitting the current words. Those choices
produce observably different continuity.

The same contract caps one live slice at 128 normalized gaps
(`specs/viewer-performance-dashboard/spec.md:109-110`; `tasks.md:12`). Store paging has `hasMore`, but
the live-slice receipt has no required total, saturation count, or `hasMore` bit. The dashboard must
set `Unplaced gap` and suppress every inter-bucket line when more than 128 gaps exist
(`specs/viewer-performance-dashboard/spec.md:152-160`), yet after silent live truncation it cannot
distinguish exactly 128 from 129. This can reconnect a line across forgotten live loss, contradicting
the conservative overflow rule.

Tasks 2.4/2.5 and 6.1 verify fixed carriers, byte accounting, and exclusion of strings; tasks 6.3/6.4
exercise storms and overflow suppression. They do not provide an independent mapping oracle or a
128/129 live receipt whose overflow survives truncation. Mutation of a direction mapping or removal
of the live overflow flag would therefore be undetectable.

**Required artifact remediation:** Enumerate every normalized gap kind and applicability value, define
the exact mapping for Store and live inputs (including direction-only/control gaps and a conservative
unknown default), and state which inputs become placed, Unplaced, or irrelevant. Add a saturating
live-gap total or `hasMore` field inside the fixed wrapper and require any truncated/interval-less
applicable gap to set Unplaced suppression. Add mapping-table tests plus 127/128/129 Store, live, and
combined-gap cases, unknown inputs, direction mutations, and proof that truncation never reconnects a
line.

## Status of Round 2 Findings

| Round 2 finding | Round 3 status | Independent verification |
| --- | --- | --- |
| R2-CT-1 deterministic accounting oracle | Closed | The artifacts define fixed charges for every retained category and an exact result formula. A maximum structural result charges 1,103,104 bytes. Event page (4,460,544), live slice (4,493,312), gap page (8,704), decoder (65,536), and shared ledger (16,777,216) sum exactly to 25,805,312 bytes. Tasks require each formula and cap to be asserted independently. |
| R2-CT-2 card-state precedence | Closed, except for the new producer-order race above | No Event means `No recent sample` with no deadline; freshness precedes typed status; invalid headers use three seconds; equality is stale; stale wins; a fresh latest Event never falls back. R3-CT-1 concerns late publication ordering, not the state matrix. |
| R2-CT-3 canonical comparators | Closed | Journal order fixes UUID network bytes, direction ordinals, and unsigned sequence. Cache order fixes source/range variants and all identity, bound, generation, and revision fields, independent of locale, descriptions, hashing, and durable/live locator. Planned equal-tie tests can reject comparator mutations. |

## Other Correctness Areas Rechecked

- Last-examined continuation, residual filtering, content/page limits, pre-byte versus post-row stops,
  injected VM/time equality, and terminal no-progress behavior remain closed and testable.
- Inclusive range arithmetic, final/interior bucket edges, live-first freeze, durable reconciliation,
  exact cache identity, LRU touch/eviction, and source/device clearing remain coherent.
- Metric-specific holes, invalid all-series breaks, wall-envelope placement, Store `hasMore`, and
  detail-loss suppression are coherent once R3-CT-2 closes the normalized/live input boundary.
- Running-plus-dirty admission, single traversal ownership, mode handoff, Pause scope rules,
  Store-unavailable recovery, generation invalidation, joined cleanup, and no-partial publication are
  otherwise implementable and proportionately covered.
- The shared Core SPI inventory is an exact ordered 16-key/group/kind contract with SDK/Viewer
  regression coverage and no public or wire-format change.

## Validation

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

git diff --check
exit 0, no output
```

Structural validity does not close the two semantic findings. This review modified no production or
test source and wrote only this report.

## Unresolved Finding Count

**2**
