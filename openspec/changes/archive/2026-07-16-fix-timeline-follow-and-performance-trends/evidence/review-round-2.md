# Review Round 2

The fresh review round confirmed the first-round production fixes and found two documentation/compatibility items.

## Findings

1. The design still described lazy tail appearance as a positive macOS 13/14 fallback signal and did not record the pending break carried by an empty discontinuous Performance bucket.
2. On macOS 13/14, newly appended content could move a previously visible lazy tail marker offscreen before the successor-row handler ran, clearing a legitimate follow intent.

## Resolution

- Updated the design to match the final fallback and pending-break semantics.
- Added a small generic fallback append state. It records the last settled Event identity, preserves an already true follow intent only while a newly appended last identity is unsettled, and settles after the tail scroll completes. An already false user intent remains false.
- Added state coverage for stable content, pending appended content, already-false follow intent, settlement, and unmount cleanup.
- Re-ran the four focused regressions: 4 passed, 0 failed.

The review found no new architecture/API, security, privacy, bounded-work, MainActor aggregation, chart clarity, or rendered-evidence issue.
