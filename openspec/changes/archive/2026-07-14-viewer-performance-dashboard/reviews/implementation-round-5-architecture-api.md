# Implementation Round 5 Architecture and API Review

Date: 2026-07-14
Verdict: Changes requested

## Findings

1. **P1 — dirty notification coverage:** the reviewed snapshot appeared to defer Store changes only
   while the change-snapshot operation was active. The latest tree already guarded the full active
   rematerialization receipt, and the correctness reviewer independently withdrew the same finding
   after refreshing. Regression coverage blocks the recording-catalog phase and proves one deferred
   successor.
2. **P1 — disconnected catalog snapshots:** recording resolution and the first device page used
   unrelated bounds. A mutation or tombstone between phases could become a generic invalid request
   and leave stale selection authority. The first device-page read must revalidate the recording
   snapshot and any mismatch must restart the entire catalog phase.

Event deactivation/reactivation ordering, overlapping replacement ownership, committed-export
ownership, repository boundaries, focused tests, strict OpenSpec validation, and diff checks passed.
Configured signing was excluded under the Goal-level deferral.
