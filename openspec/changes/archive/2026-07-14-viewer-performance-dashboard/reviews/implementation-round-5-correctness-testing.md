# Implementation Round 5 Correctness and Testing Review

Date: 2026-07-14
Verdict: Changes requested

## Findings

1. **P1 — cross-catalog generation gap:** the first device page did not prove that the recording
   snapshot remained current. A recording/tombstone mutation between phases could finish the receipt
   without a whole-phase restart.
2. **P2 — missing combined committed-export race:** one test rematerialized without replacing the
   gateway generation, while another invalidated a committed export without rematerializing. One
   combined test must cover generation invalidation, deferred authoritative delivery, the retained
   controller execution slot, and exactly-once cleanup.

The refreshed tree fixed the initially reported dirty-phase concern; the reviewer withdrew it after
the seven focused tests passed.
