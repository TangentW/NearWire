# Implementation Round 7 Architecture and API Review

Date: 2026-07-14
Verdict: Changes requested

## Findings

1. **P1 — source switching can strand the rematerialization receipt:** selecting another source
   during the device-page or exact-device phase cancels the only device operation, suppresses its
   callback, and leaves the active rematerialization work ID unfinished. Explicit Live recovery must
   cancel and retire the active catalog phase, complete dirty-successor bookkeeping, and install only
   a live materialization. A new historical source must restart rematerialization for that logical
   identity.
2. **P2 — unresolved presentation can reappear:** `selectedRecordingRow` checked row and logical
   identity but did not require resolved Store authority. An ordinary refresh could therefore show
   the selected recording again while query and management authority remained unavailable. The same
   resolved-state invariant must protect presentation, target lookup, and durable materialization.

The reviewer confirmed that terminal cleanup, filter/all-device/paging query gates, exact
row-plus-logical target identity, the internal content-driver seam, frozen snapshot linkage,
committed export ownership, and dirty-successor behavior otherwise remained sound. Six focused
tests, strict OpenSpec validation, and diff checks passed. Signing work was excluded under the
Goal-level deferral. No files were changed by the reviewer.
