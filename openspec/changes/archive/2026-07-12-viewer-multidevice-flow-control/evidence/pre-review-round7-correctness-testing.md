# Pre-Implementation Correctness and Testing Review — Round 7

Date: 2026-07-13

## Scope

Re-read `AGENTS.md`, every current `viewer-multidevice-flow-control` artifact, the prior correctness/testing review chain, companion review evidence relevant to the latest remediations, and the refreshed validation record. This artifact-only review verified the four-state 16-slot evidence matrix and regressed every lifecycle, identity, policy, receipt-time, decoder/token, ingress, sequence, queue, telemetry, and workspace requirement and test oracle. No production or test source was modified; this report is the only added file.

## Round 6 Finding Disposition

### Negotiating ownership omitted from 16-slot evidence — Resolved

Proposal and design now describe one 16-owner bound across provisional attachment, policy negotiation, active transfer, and disconnecting cleanup (`proposal.md:7`; `design.md:13,30-38`). Task 5.1 requires the exact boundary for pure and mixed provisional, negotiating, active, and disconnecting ownership through cleanup. Task 5.3 adds a barrier-controlled mixed 16-owner registry, 17th rejection, and exact multi-session handle/slot/task cleanup (`tasks.md:26-28`). These tests match the normative any-mixture scenario and prove that ownership neither disappears during state transitions nor releases before exact cleanup (`spec.md:3-13`).

## Full Regression Verification

### Lifecycle, capacity, and correlation

- All provisional, negotiating, active, and disconnecting owners share exactly 16 slots through cleanup; the separate admission-owner bound remains 32.
- Recent rows remain capped at 64, evict deterministically, use one manager expiry wake, publish at most 16 owned plus 64 recent rows, and leave zero row/wake ownership after shutdown.
- Exact correlation-tuple duplicates are rejected in both admission policies. Same-installation different/missing-Bundle variants remain separate unauthenticated rows and inherit no nickname, selection, connection, session, or downlink work.
- Downlink ownership remains bound to one internal connection ID and epoch and never migrates to a later correlation match.
- Returning connections use ordinary negotiating state; no undefined `reconnecting` presentation state remains.

### Policy and receipt-time arbitration

- Initial and dynamic offers use injected, non-resetting 10-second monotonic deadlines beginning before encoding/mailbox admission. Equality is timeout.
- V1 keeps one offer pending, accepts a protocol-valid conservative pair, attributes an indistinguishable lower pair to the current transaction, and closes an observable no-pending repeat.
- Each frame uses the sample of the callback that completes it. The sample consistently governs sender/system buckets, receiver-local TTL, policy arbitration, throughput, and every receive-time decision.
- A retained pre-deadline acceptance commits independent of timeout/continuation queue order. Deadline-equal/later samples cannot mutate effective policy. Physical terminal, cancellation, and shutdown remain immediate winners.
- Recorded timeout classification is finite. A matching complete acceptance commits; a violation closes; `drained` or `needsMoreBytes` without acceptance clears partial bytes, resolves the token without rearm, and closes once.
- Tasks require deadline-minus-one, equality, deadline-plus-one, timeout on both sides of continuation, physical-terminal/shutdown winners, and exact requested/effective/deadline/close state.

### Decoder, receive token, and bounded work

- The decoder exposes `pausedOnCompleteFrame`, `needsMoreBytes`, and `drained`. Only a complete paused frame retains one generation-bound token and one continuation.
- Secure-channel pause is claimed synchronously, prevents receive rearm and byte overtaking, and leaves no second callback `Data` while paused.
- In the ordinary path, partial tails remain charged, discard the old completion sample, detach token/continuation before resume, and use the later completing callback's sample. Immediate completion can claim only one fresh token.
- Resume-first and terminal-first are both defined. Terminal, decoder failure, attachment rollback, channel cancellation, and shutdown converge to zero decoder bytes, callback `Data`, token, continuation, receive request, queue, and handle residue; stale-generation resume is a no-op.
- Total connection input is overflow-safely validated against a 2 MiB live default and 19 MiB hard maximum. Service quanta, legal batch atomicity, sender/system buckets, one continuation plus one successor bit, and no recurring idle timer keep work finite.
- Equal-sample split/coalesced deliveries have identical protocol, token, timeout, terminal, queue, and sequence outcomes. Genuinely later split samples may produce only their documented later-time effects.

### Sequence, queue, and presentation evidence

- A structurally and route-valid inbound whole frame commits its contiguous sequence range before local expiry/overflow; malformed, wrong-route, noncontiguous, deadline-overflowing, token-violating, or hard-limit input commits none.
- Downlink sequence, exact queue removals, fairness, rate tokens, and telemetry commit only when one whole encoded frame is atomically admitted to the secure mailbox. Rejection retries the same tentative range without a gap, duplicate, or partial prefix.
- Queue count, byte, single-Event, TTL, priority overflow, normal/keep-latest, route, mailbox rejection, earlier-success/later-failure, batching, Control reservation, storm, drop-summary, saturation, and shutdown cases all have exact state assertions in Tasks 5.2 and 5.3.
- Workspace state, requested/effective labels, selection behavior, disconnected mutation rules, accessibility, latest-only safe snapshots, closed diagnostics, persistence exclusions, privacy-manifest inspection, and later-scope exclusions remain explicitly test- and documentation-owned.

## Findings

None.

## Verdict

**Approved for the correctness/testing artifact-review dimension. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**

The artifact state machines and evidence plan are total, bounded, ordered, and testable. Production or test implementation may begin only after the parallel architecture/API and security/performance/documentation reviews also report zero unresolved findings and the repository's pre-implementation review gate is completed.
