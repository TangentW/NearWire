# Implementation Round 6 Architecture and API Review

Date: 2026-07-14
Verdict: Changes requested

## Finding

1. **P1 — unresolved authority could be recreated:** terminal failure retained the historical numeric
   recording ID. A later `selectAllDevices` or filter action could call `applyScope`, reconstruct an
   all-device durable query for that stale row ID, and install it. Later-phase failure could also
   leave partial recording/device rows and mappings. Unresolved historical state must clear partial
   identity and remain non-executable until successful logical-ID rematerialization or an explicit
   switch to Live.

Snapshot linking, whole-phase restart, exact-absence-only Live reset, committed-export ownership, and
the full-receipt dirty successor passed. Four focused tests, strict OpenSpec validation, and diff
checks passed. Configured signing was excluded under the Goal-level deferral.
