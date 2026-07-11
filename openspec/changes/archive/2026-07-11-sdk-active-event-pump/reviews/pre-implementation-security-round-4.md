# Pre-Implementation Security, Performance, and Documentation Review — Round 4

Re-read the complete current proposal, design, task plan, seven capability deltas, all Round 3 reviews, and the Round 3 remediation note against the existing callback ingress, permanent session core, queue, token bucket, secure mailbox, public stream, shutdown, transport, packaging, and documentation boundaries. Round 3 remediation closes its pause-aware ingress, captured-token allowance, persistent owner-availability, and binding-lifetime design gaps except for one contradictory normative deadline sentence.

## Finding

### HIGH — Successful wake registration can cancel the only policy deadline and permit remote resource retention

**Evidence**

- The design starts one reference-tokenized initial-policy deadline synchronously at runner claim and requires that same deadline to cover both `bindingActiveOwner` and initial policy negotiation until activation (`design.md:48-52`). The session-admission delta repeats that the deadline remains live through both phases (`specs/sdk-session-admission/spec.md:5-9`), and the Round 3 remediation says only activation or terminal cleanup invalidates it (`reviews/pre-implementation-remediation-round-3.md:9-11`).
- The main binding requirement initially states the same continuous lifetime, but then says “registration or activation first SHALL invalidate the exact deadline token” (`specs/sdk-active-event-pump/spec.md:52-58`). Registration success necessarily precedes a newly received initial policy offer and may also precede consumption of a buffered offer. Literal compliance therefore disarms the only deadline immediately after owner binding, before policy activation.
- The later fail-closed scenario requires a Viewer that never offers policy to terminate with `policyNegotiationTimedOut` and release all pump registration and retained work (`specs/sdk-active-event-pump/spec.md:297-315`). That outcome is impossible after a registration-first implementation follows the contradictory invalidation sentence.
- Task 4.4 names registration-before-deadline and activation-versus-deadline races but does not state that registration-first must keep the same deadline armed through a no-offer negotiation period (`tasks.md:19-22`). Strict structural validation cannot detect this semantic contradiction.

**Impact**

After mandatory TLS admission, a faulty or hostile Viewer can allow wake registration to succeed and then withhold the initial policy offer. Under the literal main requirement, no policy timeout remains to close the operation gate. The activation waiter, permanent core, TLS channel, wake callback, signal ingress, exact NearWire reference, cancellation relay, and active dependency closures can remain live indefinitely. Individual queues remain bounded and no recurring poll is required, but bounded memory does not make an unbounded session lifetime fail closed; this is a remotely triggerable availability and resource-retention defect.

**Required remediation**

Replace “registration or activation first” with “activation or terminal cleanup first” in the normative binding requirement. Registration-first must transition from owner binding into policy negotiation without cancelling, replacing, or invalidating the existing deadline. Deadline-first must close terminal authority and prevent assignment or clean the exact late registration token; registration-first must preserve the same tokenized deadline until a valid initial offer activates the pump or another terminal cause wins.

Expand Task 4.4 so the registration-first barrier completes a live bind, withholds the initial offer, fires the same deadline, and proves exactly one `policyNegotiationTimedOut` result, no active handle, exact wake-token removal, stopped ingress and signal routing, at-most-once channel cancellation, released dependency closures and waiters, and no live deadline or successor Task. Keep distinct activation-first, owner-unavailable-first, cancellation-first, and stored-terminal-first stale-deadline cases.

## Round 3 Findings Verified Closed

- **Pause-aware ingress:** `running`, `nonterminalPaused`, and `stopped` are lock-linearized separately from the scheduled-drain latch. A late scheduled callback parks and clears the latch without consuming input; repeated paused nonterminal input creates no Task; terminal or overflow authorizes exactly one bypass drain; live resume authorizes one retained-input drain; and stop suppresses every successor. The task matrix covers terminal, overflow, resume, stop, accounting, lost-wake, and no-spin orderings.
- **Captured token allowance:** the core refreshes one bucket copy at the captured selection time, passes its nonnegative whole-token allowance separately from service and byte bounds, and the actor cannot mailbox-commit more live Events than that allowance. A live matching result uses a nonthrowing prevalidated subtraction on the exact copy before atomically installing bucket and sequence state. Invalid allowance use remains an internal programmer-contract violation rather than peer-derived input, and the production path establishes the invariant before irreversible admission.
- **Level-triggered owner loss:** registration and every schedule refresh/drain distinguish persistent shutdown from a live empty queue. Shutdown-first assigns no callback; assignment-first persists unavailability before signalling; a pre-result signal remains latched for a live-binding refresh; and empty, zero-rate, policy-negotiation, and active states terminate with `ownerUnavailable` without polling.
- **Terminal and resource bounds:** every wake assignment, expiry, route drop, accepted candidate, and incoming publication retains its small shared-gate ordering. Queue service, callback ingress, decoded FIFO plus in-flight bytes, deadline heap, secure mailbox, deferred policy transactions, signal tasks, core tasks, and one-shot decision wakes all have explicit hard or constant bounds and terminal cleanup.
- **Privacy and boundaries:** active errors remain code-only and omit pairing, identity, route, endpoint, policy, queue, Event, wire, certificate, peer, and underlying-system content. Mandatory TLS is inherited without a new plaintext path or authentication/delivery overclaim. The plan adds only an internal SPI composition seam and requires SwiftPM/CocoaPods API, dependency, entitlement, privacy, retention, task/timer/power, documentation, and evidence audits; no supported connection API, process lease, persistence, Keychain, lifecycle, UI, or performance collection is introduced.

## Validation

Command:

```text
DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive
```

Result: PASS — `Change 'sdk-active-event-pump' is valid` (exit 0).

Command:

```text
git diff --check
```

Result: PASS (exit 0, no output). The active OpenSpec change remains untracked as a whole; this review modified no production or test source.

## Review Status

One unresolved actionable finding remains. Pre-implementation security/performance/documentation closure is not granted until the continuous-deadline contradiction is remediated and a fresh independent round reports zero unresolved findings.
