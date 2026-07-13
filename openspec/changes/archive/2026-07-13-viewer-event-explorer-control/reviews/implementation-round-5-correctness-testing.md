# Correctness and Testing Implementation Review — Round 5

## CT-R5-001 — P1 High: a short lifecycle-managed session loses its transient Event

If `sessionStarted`, Event offer, and `sessionEnded` all occur before projection drains, the end
callback removes the only pending frozen metadata and retains only timestamps. Drain cannot
materialize the terminated session, applies no termination, and then discards the already accepted
Event because the connection is neither active nor resident. During storage unavailability this loses
the only Event content despite free count and byte capacity.

Retain bounded frozen metadata with a pending terminal transition, or an equivalent bounded
authoritative lifecycle state. Materialize the exact ended session and Event during drain and apply its
terminal state. Add blocked-queue regressions for this schedule both during the initial direct-to-
lifecycle transition and after lifecycle mode is established. Require terminal disposition/session
state with zero capacity-overflow or diagnostic loss.

Direct disposition, actual lifecycle transition, and the bounded/joined store-status refresh owner
otherwise verified. Four focused unsigned tests, diff hygiene, and strict OpenSpec validation pass.
Signing remains deferred and is not a finding.

**Unresolved findings: 1**
