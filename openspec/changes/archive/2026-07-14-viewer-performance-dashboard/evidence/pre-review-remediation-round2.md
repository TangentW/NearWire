# Pre-Review Round 2 Remediation

Date: 2026-07-13

Scope: artifact-only remediation before implementation. No production or test source was modified.

## Findings addressed

1. The fixed V1 metric vocabulary is now owned by Core `NearWireInternal` SPI. The proposal,
   design, new `performance-snapshot-schema` delta, tasks, and test plan require SDK and Viewer to
   consume the same ordered 16-key/group/kind inventory with no duplicate raw-string enum.
2. Deterministic scratch accounting now includes Store and live gap carriers. Exact maxima are
   4,460,544 bytes for one Store Event page, 4,493,312 bytes for one live slice including 128 gaps,
   8,704 bytes for one Store gap page, and 65,536 bytes for one decoder buffer. Together with the
   16,777,216-byte shared derived ledger, the exact performance-owned peak is 25,805,312 bytes.
3. The shared memory ledger now defines the charge for every retained object and the exact result
   formula. Immutable result content is charged once when presentation and delivery wrappers share
   it; distinct pending results are charged independently.
4. Card state now has one precedence: find the latest raw Event within 180 seconds, show No recent
   sample with no deadline if none exists, evaluate freshness before typed state, use a three-second
   horizon for an invalid/unreadable header, treat equality as stale, and never fall back from the
   fresh latest Event to an older metric.
5. Journal and cache ties now use canonical composite byte/ordinal comparators. They never depend on
   locale, descriptions, hashing, or a live-versus-durable locator.

## Validation

- `git diff --check`: exit 0, no output.
- `openspec validate viewer-performance-dashboard --strict`: exit 0; reported
  `Change 'viewer-performance-dashboard' is valid`.
- `openspec show viewer-performance-dashboard --json`: exit 0; parsed 11 deltas including the new
  `performance-snapshot-schema` delta. OpenSpec telemetry flush emitted network-only PostHog warnings
  because `edge.openspec.dev` was unavailable; artifact parsing and validation still completed with
  exit 0.

Fresh independent Round 3 architecture/API, correctness/testing, and
security/performance/documentation reviews are required before task 1.2 or any source task may be
marked complete.
