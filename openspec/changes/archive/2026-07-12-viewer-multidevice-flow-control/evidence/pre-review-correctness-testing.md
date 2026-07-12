# Pre-Implementation Correctness and Testing Review

Date: 2026-07-13

## Scope

Reviewed `AGENTS.md` and every artifact in the active `viewer-multidevice-flow-control` change: proposal, design, capability specification, tasks, README, configuration, and pre-implementation validation evidence. This was an artifact-only review of requirement testability, state and race totality, finite-resource limits, negative paths, and task-to-evidence alignment. No production or test source was modified; this report is the only added file.

## Findings

### 1. P2 / Medium — Logical-route lifecycle is not total, and recent-disconnect rows have no hard count bound

**Confidence: 10/10**

The 16-entry session bound covers negotiating and active sessions (`spec.md:5`), but disconnected routes may remain as presentation rows for 30 seconds without any count or byte bound (`spec.md:31`). A valid peer can repeatedly activate and disconnect distinct logical routes, releasing session slots while accumulating reconnect rows inside that window. The stated 16-session bound therefore does not bound the manager registry, reconnect-expiry records, sidebar snapshots, or associated one-shot expiry bookkeeping under churn.

The route state machine is also incomplete for races that determine ownership and presentation:

- candidate activation versus old-session terminal completion;
- candidate failure versus old-session disconnection;
- per-device Disconnect while an active route also has a negotiating candidate;
- manager shutdown versus candidate activation and atomic swap;
- reconnect at the exact expiry boundary; and
- late old/candidate callbacks after swap or row replacement.

The requirements define ordinary replacement success, candidate failure, and a third duplicate, but not these competing transitions (`spec.md:27-47,195-210`). Task 2.2 names replacement and reconnect rows, while tasks 5.1 and 5.3 do not require a complete route-transition matrix, expiry-boundary tests, or repeated multi-wave churn (`tasks.md:9,26-28`). An implementation could plausibly remove the healthy route, disconnect only one of two owned connections, revive an expired row, or retain unbounded recent rows while still satisfying the listed scenarios.

**Required resolution:** define a hard global count bound for recent-disconnect rows, deterministic eviction at capacity, and whether one manager-wide replaceable expiry wake or another explicitly bounded owner services them. Add a total transition table for active, replacement-candidate, recently-disconnected, expired, disconnecting, and shutdown states, including the races above and exact 16-slot release behavior. Extend tasks 5.1/5.3 with injected monotonic-clock and barrier tests for both winner orders, exact row/session/task counts, multi-wave distinct-route churn, expiry at 30 seconds, and zero retained ownership after shutdown.

### 2. P2 / Medium — Initial and dynamic policy deadlines do not define a deterministic timing and terminal contract

**Confidence: 10/10**

The initial policy acceptance has one 10-second monotonic deadline, but the artifacts do not specify its start boundary. Plausible choices include successful handoff transfer, session attachment, acknowledgement/offer mailbox admission, or send completion (`spec.md:49-53`; `design.md:46-52`). Those choices differ when Control admission or sending is delayed. It is also unclear whether the deadline includes the time needed to enqueue both initial frames and whether any phase transition may reset it.

Dynamic updates close on a “policy timeout,” but no duration, start boundary, or replacement rule is normative. The artifacts also lack total winner rules for acceptance versus timeout, terminal input versus acceptance, send/admission failure versus user edits, and shutdown versus a pending offer. “At most one offer in flight” and latest-only desired policy do not determine whether a concurrently accepted generation may activate the latest edit or must first send another offer.

Task 5.1 requests initial/dynamic/timeout/escalation tests, but it does not require an injected scheduler, both controlled winner orders, one exact terminal result, no stale effective-policy mutation, or no post-terminal offer (`tasks.md:26`). A wall-clock implementation or a test that checks only eventual timeout could pass while retaining timing races.

**Required resolution:** define one monotonic start point and non-resetting duration for initial negotiation and for every dynamic offer, including behavior when mailbox admission or send fails. Add a compact transition table over attachment, initial-offer-pending, active, update-pending, latest-desired, terminal, and shutdown states. Specify exact winners for timeout/acceptance/terminal/edit races and whether a matching acceptance changes only the offered generation before the latest desired pair is sent. Amend task 5.1 to require an injected clock and explicit barriers, both winner orders, exact generation/effective/requested state, exact close count, and absence of stale callbacks or extra offers.

### 3. P2 / Medium — Event sequence consumption is ambiguous across expiry, queue loss, and failed downlink admission

**Confidence: 10/10**

Inbound Events require a strict contiguous sequence and receiver-local TTL validation. Expired Events are dropped rather than delivered (`spec.md:101-105`). The artifacts do not state whether a structurally valid but expired Event consumes the next expected sequence. If it does not, the following valid Event necessarily appears to have a gap and closes the session; if it does, sequence state must advance atomically before local expiry/drop accounting. The same ambiguity applies when a valid inbound Event is accepted at the wire boundary but later lost by the bounded uplink queue's priority/overflow policy.

Outbound values receive their sequence and wire envelope “only at transport admission time” (`design.md:68-72`; `spec.md:103-110`), but the atomic boundary is not defined. If a batch is encoded and assigned sequences before secure-mailbox admission is rejected or only a prefix is accepted, the implementation may either consume unsent sequences and create a wire gap or reuse a sequence after partial ownership transferred. Keep-latest replacement and TTL expiry before admission must likewise never consume a wire sequence.

Task 5.2 lists TTL and sequence tests independently but does not require the combined cases, partial-prefix admission, mailbox rejection/retry, or exact queue/sequence/drop state (`tasks.md:27`). The current scenarios therefore cannot distinguish two incompatible implementations.

**Required resolution:** specify that every syntactically and route-valid inbound wire Event advances (or does not advance) the expected sequence under each local expiry and queue-drop outcome, with one explicit consistent rule. Define the downlink commit point at which a sequence becomes consumed, including atomic mailbox rejection, accepted-prefix ownership, retry, local expiry, and keep-latest replacement. Extend task 5.2 with deterministic combined tests proving next-sequence values, emitted wire sequences, no duplicate/gap after rejected admission, exact queue ownership, and local drop/expiry summary counts.

## Verified Strengths

- The change preserves one immutable connection core, callback, decoder, and terminal gate across admission and active operation.
- The 16 negotiating/active session limit and independent 32 admission-owner limit are explicitly separated, and the 17th synchronous rejection path preserves original admission cleanup ownership.
- Queue count, byte, and single-Event bounds are concrete; direction rates, 500 ms batching, Control reservation, latest-only UI delivery, and no recurring idle timers are expressed as observable behavior.
- Requested and effective policies are separated, escalation is rejected, only one update is in flight, and zero-rate Control progress is explicitly required.
- Preference record counts, corruption behavior, nickname validation, and deterministic LRU tie-breaking are testable through injected `UserDefaults` and time.
- Sensitive/content-free telemetry boundaries, session isolation, same-core lifecycle cleanup, excluded later-product scope, and no-new-harness policy are clear.
- Tasks already require focused unit, queue/pump, concurrency integration, presentation, packaging, documentation, independent review, and spec-to-evidence audit stages. The findings concern missing cases and exact oracles, not a need for a new test framework.

## Evidence Expectations After Remediation

The existing XCTest-based strategy remains proportionate. After artifact remediation, implementation evidence should include:

- deterministic state-machine tests using injected monotonic time and explicit barriers rather than sleeps;
- exact session, recent-row, queue, timer/wake, task, handle, and admission-slot counts at capacity and after multi-wave cleanup;
- both winner orders for policy, replacement, disconnect, terminal, expiry, and shutdown races;
- combined TTL/sequence/overflow/mailbox-admission assertions rather than isolated happy-path checks;
- 1/4/8/16-device integration with one blocked or invalid device and observable progress for another;
- real SDK-compatible handshake and bidirectional Event exchange without claiming delivery acknowledgement or persistence; and
- final requirement-to-evidence mapping plus the existing Viewer/Core/SDK and repository validation gates.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 3 — 0 High, 3 Medium, and 0 Low.**

The architecture direction is coherent, but the recent-row resource lifetime, policy deadline races, and Event sequence commit rules must become normative and appear in the task evidence matrix before implementation begins.
