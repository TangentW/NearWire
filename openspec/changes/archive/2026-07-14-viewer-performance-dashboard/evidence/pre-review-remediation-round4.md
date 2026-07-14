# Pre-Review Round 4 Remediation

Date: 2026-07-13

Scope: artifact-only remediation before implementation. No production or test source was modified.

## Historical clock-domain remediation

Absolute freshness deadlines and injected current-uptime claim/apply validation now apply only to a
current source. Historical cards evaluate once against the frozen historical upper in the same
recording monotonic domain and never schedule a deadline callback. Checked distance at or beyond the
metric horizon is No recent sample; otherwise the latest typed state remains frozen. Pause does not
age historical cards. Current/historical switching invalidates and joins the prior receipt before the
successor uses its own clock domain. Tests now include historical anchors below, equal to, and above
current uptime, simulated uptime reset, source switching, Pause, cleanup, one current wake, and zero
historical wakes.

## Store applicable-overflow remediation

The fixed 512-byte Store gap-page wrapper now carries generic `hasMoreRows`, a saturating
performance-or-uncertain count, and `hasMoreApplicableGaps`. Store classifies the frozen matching
metadata scope under the existing 2,000,000-VM-step, injected-250-ms, cancellation, and plan gates.
Hidden irrelevant-only rows set only generic pagination; a hidden performance or uncertain row sets
applicable overflow. Classification budget exhaustion returns applicable overflow true regardless of
the partial count and cannot claim complete classification. Paired fixtures with identical retained
128 irrelevant carriers and different 129th-row applicability, plus mixed Store/live boundaries,
make the distinction mutation-testable.

## Validation

- `git diff --check`: exit 0, no output.
- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive`:
  exit 0; reported `Change 'viewer-performance-dashboard' is valid`.

Fresh Round 5 reviews in all three required dimensions must report zero unresolved findings before
task 1.2 or any source task may be marked complete.
