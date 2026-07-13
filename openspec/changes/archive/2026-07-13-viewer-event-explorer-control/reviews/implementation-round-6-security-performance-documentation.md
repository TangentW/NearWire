# Security, Performance, and Documentation Implementation Review — Round 6

## SPD-R6-001 — P1 High: controller cancellation creates untracked MainActor result tasks

Controller cancellation completes its tracker before asking the gateway to cancel. A queued gateway
cancellation invokes rejection synchronously, and every controller completion creates a MainActor task
before checking stale/sealed state. Repeated same-slot replacements can therefore enqueue one untracked
content-bearing task per cancellation, and cleanup can wait a zero tracker while an active callback can
still enqueue another task.

Give every controller operation a lock-protected cancellation/delivery bridge. A callback must
atomically claim exactly one tracked delivery; cancelled callbacks complete without creating a task,
and cancellation after a claim leaves the tracker owned until the MainActor task handles or discards
the result. Add a 100,000-replacement controller regression plus an active-result/cleanup race.

## SPD-R6-002 — P2 Medium: managed-session retirement leaves detached conflict markers

`journalConflict` can remove an Event while retaining its marker. Direct-to-managed reconciliation
now removes connection-owned markers, but normal ended-session reclamation and terminal capacity
eviction remove the session without removing detached markers. Repeated managed sessions can fill the
marker ring with stale diagnostics.

Centralize or complete connection retirement so every managed reclamation/capacity path removes its
markers. Add managed lifecycle and capacity-pressure regressions requiring zero detached marker state
and accurate diagnostics, and correct evidence wording to the proven ownership rule.

Status provider coalescing, gateway queue bounds, terminal metadata, zero-owner authority, privacy,
reflection, clipboard, export disclosure, formatting, and strict OpenSpec validation otherwise pass.
Signing and embedded-entitlement verification is deferred and is not a finding.

**Unresolved findings: 2**
