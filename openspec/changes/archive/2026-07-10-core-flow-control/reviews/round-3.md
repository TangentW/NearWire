# Review round 3

## Result

- Correctness and testing: zero findings, ready to archive.
- Architecture and API: one documentation naming drift.
- Security, performance, documentation, and evidence: two findings.

## Finding and resolution

The design named a nonexistent `EffectiveEventRates` type even though the implemented API is `DirectionalEventRates.effective`. The design now uses the exact API name. This correction changes no production or test source and does not invalidate canonical run `20260710T231509Z-29426`.

The zero-token scheduler path built a full mutable snapshot, scanning every live event on every paused or token-starved flush. It now calls a module-internal expiration-only operation backed by the deadline heap. A regression fills the 10,000-entry hard bound and performs 1,000 paused due attempts without removing live work.

The canonical OpenSpec evidence also predated the architecture documentation correction. Tasks 7.1 and 7.2 are reopened until one new all-mode run replaces every raw log and validation summary.

A fresh final review round is required after the documentation correction and completion audit.
