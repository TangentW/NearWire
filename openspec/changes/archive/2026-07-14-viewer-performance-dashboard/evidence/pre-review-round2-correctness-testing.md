# Correctness and Testing Artifact Review — Round 2

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Changes are still required before implementation.** This was a fresh review of the current
proposal, design, delta specifications, tasks, and existing evidence after Round 1 remediation. The
review did not treat any Round 1 conclusion as inherited. CT-1, CT-4 through CT-6, and CT-9 through
CT-10 now have implementable, mutation-sensitive contracts. CT-2, CT-3/CT-8 tie behavior, and CT-7
still contain three independent specification gaps described below.

Configured signing and inspection of entitlements embedded in a signed product remain deferred by
product-owner decision to Goal-level `release-hardening`. That deferred gate is not a finding in this
review.

## Findings

### R2-CT-1 — P1 (confidence: 10/10): the deterministic memory ledger has ceilings but no accounting oracle

The revised artifacts enumerate the values owned by the shared ledger and state 8-MiB per-result,
16,777,216-byte shared-ledger, 4,456,448-byte page/slice, 65,536-byte decoder, and exact
25,755,648-byte peak ceilings (`specs/viewer-performance-dashboard/spec.md:76-95`;
`design.md:96-110`). The page rule has an exact oracle—actual copied content plus 512 bytes per
carrier—but no equivalent formula defines the deterministic charge for a bucket, numeric
accumulator, categorical summary, gap, invalid diagnostic, journal/cache key, presented model,
delivery, tooltip, chart mark, or accessible summary. “Charging immutable values once” defines
ownership, not their byte charge.

Consequently, two implementations can retain identical objects yet report different deterministic
bytes and both claim compliance. A mutation that undercharges or omits a retained category cannot be
detected independently: tasks 3.2, 6.3, and 6.7 can only assert the implementation's own accounting.
The exact peak is currently only the arithmetic sum of ceilings, not evidence that every object
inside the shared ceiling is charged correctly. This leaves CT-2 only partially resolved.

**Required artifact remediation:** Add one normative accounting table or formula for every retained
fixed and variable-size value, including checked-addition/admission order, collection capacity versus
logical count, immutable-sharing transfer, and release. Add independent fixture totals at zero,
single-value, cap-minus-one, exact-cap, and cap-plus-one boundaries, plus mutations that omit,
double-charge, and undercharge each category.

### R2-CT-2 — P2 (confidence: 10/10): card freshness conflicts with latest invalid/missing/unavailable state

Cards must show `Invalid` for the latest invalid snapshot and the latest missing or unavailable state
without fallback, but freshness equality must show `No recent sample`
(`specs/viewer-performance-dashboard/spec.md:116-120`; `design.md:125-129`). Both rules apply when the
latest eligible snapshot is stale. The artifacts do not state whether stale overrides Invalid,
Permission denied, Temporarily unavailable, Disabled, Unsupported, or Not collected, nor how a
malformed snapshot with no decodable sample interval arms the freshness deadline. They also do not
state the card result when no performance Event exists within the 180-second lookback.

Task 6.2 covers latest-invalid/latest-missing inputs and task 6.4 covers lookback and freshness
equality independently, so neither task defines a mutation-sensitive cross-product oracle. Choosing
`No recent sample`, preserving the metric state, or using different precedence for invalid and
unavailable input would all be implementation-time product decisions. CT-7 is therefore not fully
closed.

**Required artifact remediation:** Define one card-state matrix for present, missing, every
unavailable reason, invalid, and no-snapshot input when fresh, exactly at the deadline, and stale.
Define the interval/deadline source when the latest snapshot is invalid, and add cross-product tests
that reject every alternative precedence.

### R2-CT-3 — P2 (confidence: 9/10): “lexical key” does not define a comparator for required ties

Equal-time samples, center-nearest representative ties, fifth-entry LRU ties, and raw reveal all
depend on a lexical journal or cache key (`specs/viewer-performance-dashboard/spec.md:52-54,70-80`;
`design.md:84-94,112-116`). The existing journal key is a composite of runtime UUID, connection UUID,
direction, and wire sequence, and the cache key is a larger composite. The artifacts do not define
field order, UUID byte/string representation, direction order, integer byte order, optional-value
order, or range-kind order.

“Lexical” therefore does not select one result. Comparing UUID descriptions, canonical UUID bytes,
or a different tuple field first can choose different metric representatives and a different cache
victim while remaining deterministic. Tasks 6.1, 6.3, and 6.4 request equal-tie tests but provide no
independent expected ordering, leaving parts of CT-3 and CT-8 non-mutation-testable.

**Required artifact remediation:** Specify canonical total-order tuples for journal and cache keys,
including every field's comparison representation and enum/optional ordering. Add fixtures whose
winner changes when any field order, direction order, UUID representation, or numeric order is
mutated.

## Resolution Audit for Round 1 CT Items

| Round 1 item | Round 2 result | Evidence in current artifacts |
| --- | --- | --- |
| CT-1 continuation and page progress | Closed | Forward-only last-examined continuation, residual-filter advancement, exact pre-byte/post-row rules, injected VM/clock boundaries, and terminal no-progress behavior are normative. |
| CT-2 page/live/global memory | Partially open | Page/content/oversize and ownership ceilings are exact; shared-ledger charge values still lack an independent accounting oracle (R2-CT-1). |
| CT-3 ranges, buckets, and cache | Partially open | Inclusive anchors, bucket formula, complete cache identity, touch, and eviction are defined; the required lexical tie comparator is not (R2-CT-3). |
| CT-4 gaps and metric holes | Closed | Frozen gap uppers, bounded gap rows, conservative wall-envelope mapping, Unplaced suppression, per-metric breaks, and overflow behavior are explicit. |
| CT-5 live/durable freeze | Closed | Live-first drained-ingress freeze, later Store uppers, anchor filtering, journal-key deduplication, and locator-only durable replacement form a testable permutation contract. |
| CT-6 refresh and freshness wake | Closed | One running scan plus one dirty successor, latest-token admission, one replaceable injected deadline, Pause behavior, and cleanup ownership are explicit. |
| CT-7 availability precedence | Partially open | Snapshot conflicts and mixed-bucket precedence are closed; card freshness versus latest metric state is not (R2-CT-2). |
| CT-8 representative identity | Partially open | Representatives are metric-specific and locator-only reconciliation is explicit; equal-time key ordering remains undefined (R2-CT-3). |
| CT-9 Pause | Closed | Authoritative replacement, paused range, unchanged-scope reveal, mode switch, Resume, and immediate predecessor clearing are explicit. |
| CT-10 Store unavailable | Closed | Historical, current live-only, mid-scan discard, recovery, Pause, and prior-chart clearing have distinct outcomes. |

## Structural Validation

The current artifacts were read in full. This review did not modify production or test source.
Strict OpenSpec and whitespace validation should be rerun after resolving the three findings.

## Unresolved Finding Count

**3**
