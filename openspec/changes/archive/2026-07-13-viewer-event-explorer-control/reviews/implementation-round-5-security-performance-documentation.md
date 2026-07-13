# Security, Performance, and Documentation Implementation Review — Round 5

## SPD-R5-001 — P1 High: status snapshots are computed before notification coalescing

`ViewerStoreStatusSignal.publish` invokes its snapshot provider before checking whether a delivery is
already scheduled. Every successful transaction therefore performs query-reader and filesystem status
work even when only one notification can be delivered. The downstream burst regressions exercise the
coalesced callbacks but not this pre-coalescing SQLite work.

Coalesce only bounded changed IDs and dirty state first. Invoke the provider on one retained worker
with at most one dirty successor, and join that worker during owner cleanup. Add a blocked-provider
100,000-publish regression proving constant provider invocations and finite cleanup.

## SPD-R5-002 — P1 High: queued gateway cancellation retains an unbounded dispatch backlog

Every gateway request inserts an operation, enters the completion group, and enqueues a capturing
closure. Cancelling queued work changes only its state; the operation record, captured values,
dispatch closure, group entry, and controller tracker remain until every predecessor executes. Rapid
replaceable operations behind one blocked reader can therefore accumulate request-proportional memory
and shutdown latency. The existing queued-cancellation regression releases the predecessor and waits
for the cancelled closure, encoding rather than detecting this retention.

Own pending work in a removable bounded queue with one scheduled drain, or retain one active plus one
latest pending request per replaceable slot. Queued cancellation must atomically remove and complete
the request without retaining one dispatch closure per cancellation. Add a blocked-reader burst
regression proving constant gateway/tracker/group ownership and prompt sealing.

## SPD-R5-003 — P1 High: lifecycle eviction can leave ownerless authority entries

Removing a resident Event retains its authority entry while deferred duplicates exist. When the final
deferred duplicate later drains, `completePendingDuplicate` decrements the count to zero but writes the
entry back even though it has no current value. Repeated blocked session churn can accumulate these
ownerless entries to the authority cap, after which every fresh key becomes `untracked` despite free
live-window and session capacity.

Remove an authority entry when its pending duplicate count reaches zero and it has no current value.
Audit all window-removal paths for the same invariant and add a multi-generation blocked duplicate-
churn regression proving authority returns to current ownership and fresh Events remain admissible
beyond the cap.

The round-4 status coordinator, SQLite/export exact cancellation, privacy, reflection, clipboard, and
documentation paths otherwise verified. Diff hygiene passes. Signing and embedded-entitlement
verification remains deferred to Goal-level `release-hardening` and is not a finding.

**Unresolved findings: 3**
