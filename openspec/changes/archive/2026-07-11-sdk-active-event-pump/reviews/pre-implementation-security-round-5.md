# Pre-Implementation Security, Performance, and Documentation Review — Round 5

Re-read the complete current proposal, design, task plan, seven capability deltas, all Round 4 reviews, and the Round 4 remediation note against the existing permanent session core, callback ingress, NearWire owner lifecycle, queue, token bucket, secure mailbox, public streams, transport, packaging, and documentation boundaries. This was a fresh closure review after the single Round 4 continuous-deadline contradiction was corrected.

## Result

Zero unresolved security, performance, or documentation findings remain in the pre-implementation plan.

## Closure Verification

### Post-registration lifetime is now bounded and fail closed

- Runner claim starts one reference-tokenized initial-policy deadline before owner binding, and the same token continuously covers binding plus initial policy negotiation (`design.md:46-52`; `specs/sdk-session-admission/spec.md:5-9`).
- The normative binding requirement now explicitly says successful registration retains that live deadline; only activation or another terminal transition invalidates it (`specs/sdk-active-event-pump/spec.md:52-58`). This agrees with the task inventory and terminal-cleanup contract (`specs/sdk-active-event-pump/spec.md:297-315`).
- Task 4.4 now includes the exact `registration-success-with-no-offer` ordering in addition to deadline-before-registration, registration-before-deadline, terminal/deadline, stale attachment deadline, and activation/deadline races (`tasks.md:19-22`). A Viewer cannot complete registration and then retain the activation waiter, channel, callback, signal ingress, NearWire reference, or dependency closures indefinitely by withholding the initial policy offer.
- Deadline-first closes terminal authority, stops paused ingress, and makes a late assignment result remove only its exact token. Registration-first remains deadline-covered until activation. Activation or another terminal winner invalidates the token so stale delivery cannot create a second terminal result.

### Earlier cross-actor and fail-closed findings remain closed

- The pause-aware callback ingress has lock-linearized `running`, `nonterminalPaused`, and `stopped` modes orthogonal to one scheduled-drain latch. Parked nonterminal work creates no Task, terminal or overflow authorizes exactly one bypass drain, live resume authorizes one retained-input drain, and stop prevents successors; no pause path self-reschedules into a spin (`design.md:48-54`; `specs/sdk-session-admission/spec.md:52-68`).
- Wake assignment, each expiry, each route drop, each accepted outbound candidate, and incoming publication use separate small shared-gate claims. Terminal-first mutates nothing; committed-before-terminal work has explicit mailbox, queue, fairness, telemetry, publication, and stale-result semantics (`design.md:80-90`; `specs/sdk-active-event-pump/spec.md:122-132,285-309`).
- Owner availability is level-triggered in registration and every schedule refresh/drain. Shutdown-first assigns no callback; assignment-first persists unavailable state before its coalesced hint; a pre-result signal remains latched for a matching live-binding refresh. Empty, policy-negotiation, zero-rate, and positive-rate states therefore cannot lose owner shutdown or require polling (`design.md:70-78`; `specs/sdk-offline-buffer/spec.md:34-66`).
- Uplink selection captures a refreshed bucket copy and its exact whole-token allowance before actor work. The drain cannot mailbox-commit more live Events than that allowance, and only a live matching result performs nonthrowing prevalidated subtraction on the exact copy before atomically installing bucket and sequence state (`design.md:92-106,120-128`; `specs/event-rate-control/spec.md:3-19`). Peer input cannot select the internal allowance or invoke the programmer-contract path.

### Memory, task, timer, and hostile-work power bounds are complete

- The secure mailbox has overflow-safe count/byte bounds, one FIFO send in flight, atomic reserved-capacity admission, constant-size capacity snapshots, and terminal byte release. A blocked uplink retains only candidate identity, size, reservation, and progress generation; insufficient completion signals do not re-encode or spin.
- Uplink queue work has positive service and byte quanta, a captured acceptance allowance, bounded expiry continuations, a bounded deadline index, and one token-or-TTL wake. Downlink has combined FIFO plus in-flight count/byte charging, an exact one-node-per-FIFO-item indexed heap, bounded publication/expiry turns, and one token-or-TTL wake. Zero-rate work expires without recurring polling.
- Callback ingress, completed frames per receive callback, retained incoming Events/bytes, deferred policy transactions, queue service/bytes, and publication work all have explicit defaults and hard maxima (`specs/sdk-active-event-pump/spec.md:224-265,297-305`). Over-limit peer work terminates rather than silently evicting or expanding retention.
- The core owns at most one policy deadline, uplink wake, downlink wake, outbound drain, and incoming publication Task. Outbound signal coalescing creates no Task before its lock transition and retains at most one routing Task plus one authorized successor. Immediate continuations are quantum-bounded actor turns, not recursive or recurring poll loops.

### Privacy, transport, dependency, and documentation boundaries are complete

- Active errors are one closed internal code set. Description, debug description, interpolation, and reflection omit pairing data, names, identities, endpoints, routes, rates, queue/Event content, wire bytes, certificates, peer text, and underlying system errors (`specs/sdk-session-admission/spec.md:72-99`; `specs/sdk-active-event-pump/spec.md:307`). Hostile drop summaries affect only saturating internal counters.
- Event transfer remains on the already admitted mandatory-TLS channel. The plan adds no plaintext path and makes no new authentication, peer-identity, acknowledgement, retry, persistence, exactly-once, or remote-delivery claim.
- The only cross-target rate seam is internal SPI. The change adds no supported SDK signature, package product, target, runtime dependency, CocoaPods subspec, entitlement, or privacy declaration, and does not claim the process lease or add persistence, Keychain, lifecycle, UI, reconnection, state publication, or performance collection (`proposal.md:21-32`; `specs/sdk-public-boundary/spec.md:3-30`).
- Tasks 7.1 through 7.7 require production TLS integration, SwiftPM/CocoaPods and API-boundary checks, English security/non-delivery documentation, retention and task/timer/power audits, exact requirement-to-evidence mapping, independent post-implementation review to zero findings, archive, and validation discipline (`tasks.md:37-45`).

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

Result: PASS (exit 0, no output). The active OpenSpec change remains untracked as a whole; this review modified no proposal, design, specification, task, production, or test source.

## Review Status

Pre-implementation security/performance/documentation review closure is granted with zero unresolved findings. Source apply remains subject to zero-finding closure from the other independent review dimensions and the repository's required task/evidence workflow.
