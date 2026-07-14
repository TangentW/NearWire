# Pre-Review Round 3 Remediation

Date: 2026-07-13

Scope: artifact-only remediation before implementation. No production or test source was modified.

## Findings addressed

### Late freshness publication

Every card result now carries source generation, latest-Event identity, an absolute Viewer-monotonic
deadline, and a deadline revision. Claim and MainActor apply both validate that receipt with an
injected clock. A result applied at or after equality may publish chart data but must publish No
recent sample cards and must not arm an elapsed deadline. The callback validates the same receipt,
fires at most once, and cannot re-arm a past deadline. Pause records one bounded expiry dirty bit;
Resume performs one fresh projection. Source/runtime replacement invalidates the receipt before
joined cleanup. The test plan crosses scan completion, delivery claim/apply, deadline, Pause/Resume,
and source/runtime replacement with barriers.

### Closed gap normalization and live overflow evidence

The artifacts now enumerate six normalized kinds and three applicability values. Case-sensitive
Store reason-prefix and direction mappings are explicit; Viewer-to-App-only evidence is irrelevant,
App-to-Viewer/both is performance-applicable, and unknown input is uncertain and conservative. Live
counter mappings are also explicit and interval-less. The live wrapper carries a saturating total
applicable loss count plus `hasMoreApplicableGaps`, retains at most 128 details, and sets the bit when
input/detail exceeds retained evidence. Interval-less applicable evidence, unknown applicability,
Store/live `hasMore`, or more than 128 combined applicable details sets Unplaced gap and cannot
reconnect a line. Scenarios and tests cover downlink-only versus unknown input and 127/128/129 Store,
live, and combined boundaries.

## Validation

- `git diff --check`: exit 0, no output.
- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive`:
  exit 0; reported `Change 'viewer-performance-dashboard' is valid`.

Fresh Round 4 reviews in all three required dimensions must report zero unresolved findings before
task 1.2 or any source task may be marked complete.
