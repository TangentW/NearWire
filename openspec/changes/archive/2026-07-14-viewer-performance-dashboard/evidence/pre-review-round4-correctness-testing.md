# Correctness and Testing Artifact Review — Round 4

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Changes are still required before implementation.** This was a fresh artifact-only review of the
current proposal, design, tasks, all five delta specifications, prior review/remediation evidence, and
the Round 3 remediation. The direct late-delivery race from R3-CT-1 is now closed, and the normalized
gap table plus live overflow receipt from R3-CT-2 are largely closed. Two cross-boundary contradictions
remain: historical monotonic timestamps do not necessarily share the current deadline clock domain,
and Store's generic `hasMore` cannot preserve the new irrelevant-versus-applicable distinction.

Configured signing and inspection of entitlements embedded in a signed product remain deferred by
product-owner decision to Goal-level `release-hardening`. That deferred gate is not a finding in this
review.

## Findings

### R4-CT-1 — P1 (confidence: 9/10): historical cards have no valid absolute-deadline clock contract

Performance supports current connections and persisted historical device sessions, whose range upper
is frozen from the historical recording (`specs/viewer-performance-dashboard/spec.md:31-50`). The
new freshness receipt is required for **every** card result and compares its absolute
Viewer-monotonic deadline with the currently injected clock at claim and apply
(`specs/viewer-performance-dashboard/spec.md:135-152`; `design.md:147-163`). The artifacts do not
distinguish current from historical card freshness.

A persisted historical `viewerMonotonic` value belongs to the uptime/recording domain in which it was
captured. After a machine restart, the current monotonic clock can be lower than that stored value;
even without a restart, applying current-wall aging to a frozen historical analysis is a different
product rule from evaluating freshness at the historical session anchor. The current contract permits
three incompatible implementations:

- compare historical sample time with the frozen historical upper and never schedule a wake;
- compare it with current monotonic `now`, making old historical cards stale; or
- schedule a future deadline from an old monotonic domain, which can make ancient data appear fresh
  after a clock-domain reset.

Tasks 6.4 and 6.5 test historical ranges and deadline races independently, but do not cross a
historical source with a lower/equal/higher current clock or prove that historical inspection owns no
live wake. R3-CT-1 is therefore closed for current-source claim/apply ordering but not for the
historical source boundary.

**Required artifact remediation:** State that absolute injected-clock deadlines are current-source
only. Define historical cards against the frozen historical anchor in the same recording domain (or
define a different explicit historical state), and require no scheduled freshness callback for a
historical source. Add tests for historical anchors on both sides of current `now`, simulated uptime
reset, historical/current source switching, Pause, and cleanup, proving no cross-domain comparison or
historical deadline wake.

### R4-CT-2 — P1 (confidence: 10/10): generic Store `hasMore` contradicts irrelevant-gap behavior

The remediation correctly defines case-sensitive kind/direction mapping and says a Viewer-to-App-only
gap is irrelevant and must not break an App-to-Viewer performance series
(`specs/viewer-performance-dashboard/spec.md:158-181,200-204`;
`specs/viewer-local-store-search/spec.md:36-42`). It also says more than 128 **combined applicable**
details or Store/live `hasMore` must set Unplaced suppression.

The Store receipt, however, still exposes at most 128 normalized rows plus one generic `hasMore`
(`specs/viewer-local-store-search/spec.md:28-34`). That bit counts hidden rows before any
applicability-specific overflow distinction. Consider two valid 129-row inputs:

1. all 129 rows are `viewerToApp` and therefore irrelevant; or
2. the first 128 rows are irrelevant and the hidden row is `appToViewer` and therefore applicable.

Both receipts can contain the same 128 irrelevant carriers and `hasMore == true`. The dashboard must
not break the first series under the irrelevant rule, but must suppress the second because applicable
evidence was truncated. Treating generic `hasMore` as Unplaced violates the first requirement;
ignoring it can reconnect the second. Unlike the live wrapper, Store has no saturating applicable/
uncertain total or `hasMoreApplicableGaps` bit capable of resolving the two cases.

Task 6.4 names 127/128/129 Store/live/combined receipts and irrelevant gaps, but the missing Store
receipt state means no implementation or mutation test can satisfy this exact pair of fixtures.
R3-CT-2 is therefore only partially closed.

**Required artifact remediation:** Normalize while scanning and add a Store-side saturating
performance-or-uncertain total plus `hasMoreApplicableGaps` (or an equivalent tri-state overflow
receipt) under the fixed wrapper budget. Generic pagination exhaustion containing only irrelevant
rows must not break the series; any hidden applicable or uncertain row must set Unplaced. Add paired
129-row fixtures with identical retained carriers but irrelevant-only versus hidden-applicable tails,
plus mixed Store/live 127/128/129 cases and mutations of the overflow classification.

## Round 3 Finding Status

| Round 3 finding | Round 4 status | Evidence |
| --- | --- | --- |
| R3-CT-1 late result reverses freshness | Closed for current scope; historical boundary remains open as R4-CT-1 | Receipt now binds source generation, latest Event identity, absolute deadline, and revision. Claim and apply both validate the injected clock; equality is stale; callbacks match the entire receipt, fire once, schedule only in the future, and Pause/source replacement have bounded invalidation rules. Tasks 3.5, 4.1/4.2, 6.4, and 6.5 require the full barrier matrix and no past re-arm. |
| R3-CT-2 normalized mapping and live overflow | Partially closed | Six kinds, three applicability values, exact case-sensitive Store reason/direction mappings, conservative unknowns, live interval-less mappings, and live `hasMoreApplicableGaps` are explicit. Generic Store `hasMore` still cannot distinguish irrelevant-only from hidden applicable overflow (R4-CT-2). |

## Other Boundaries Rechecked

- Candidate traversal, last-examined progress, byte/row/VM/injected-time equality, terminal
  no-progress, cancellation, lease release, and Store-generation rejection remain closed.
- Live-first freeze, durable reconciliation, inclusive ranges, bucket geometry, canonical journal and
  cache comparison, LRU behavior, and source/device clearing remain implementable and testable.
- Per-object accounting remains arithmetically consistent: the maximum structural result is
  1,103,104 bytes, and the shared ledger plus Event page, live slice, gap page, and decoder sum to the
  stated 25,805,312-byte peak.
- Availability conflicts, card state precedence, metric-specific holes and representatives, raw
  reveal, mode handoff, Pause scope replacement, Store unavailable/recovery, claimed cleanup, and
  privacy clearing retain proportionate planned coverage.
- The Core SPI move retains one exact ordered 16-key inventory without changing public API or encoded
  JSON.

## Validation

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

git diff --check -- openspec/changes/viewer-performance-dashboard
exit 0, no output
```

Structural validation does not resolve the two semantic contradictions. No production/test source or
other artifact was modified; this report is the only file written by this review.

## Unresolved Finding Count

**2**
