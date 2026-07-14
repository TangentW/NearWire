# Implementation Round 8 Correctness and Testing Review

Date: 2026-07-14
Verdict: Changes requested

## Finding

1. **P2 — active historical-to-historical restart lacked direct evidence:** the Live-switch
   regression proved receipt retirement, but no gated test selected another historical source while
   first-device or exact-device rematerialization was active. Add a test proving predecessor
   cancellation, fresh logical catalogs, exactly-once receipt completion, one dirty successor, and
   zero controller/gateway work.

The exact-device failure, post-terminal action matrix, unresolved authority guards, snapshot,
export, dirty-successor, and internal-seam behavior otherwise passed inspection. Eight fresh focused
tests passed with no failure or skip; recorded repetition was 40/40, complete Viewer was 391 passed
and 2 skipped, and root package was 539 passed. Strict OpenSpec validation and diff checks passed.
Signing work was excluded under the Goal-level deferral. No files were changed by the reviewer.
