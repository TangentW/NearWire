# Pre-Implementation Architecture and API Review — Round 4

Re-read the complete current proposal, design, task plan, all seven capability deltas including `event-rate-control`, every Round 3 independent report, and the Round 3 remediation note. Re-checked the revised contracts against the current permanent session core, callback ingress, NearWire actor lifecycle, token bucket, SwiftPM/CocoaPods target graph, secure mailbox, queue, and supported API boundary. Round 3 remediation closes the ingress scheduler, captured-token allowance, owner-availability, and binding-start deadline structures, but one contradictory deadline sentence remains normative.

## Finding

### HIGH — Wake registration is still specified to cancel the deadline that must cover policy negotiation

**Confidence:** 10/10

**Evidence**

- The binding requirement first says one initial-policy deadline starts before actor suspension and continuously covers owner binding plus initial policy negotiation until activation. The same sentence then says “registration or activation first” invalidates that exact token (`specs/sdk-active-event-pump/spec.md:52-54`). Registration success is only the transition from `bindingActiveOwner` into policy negotiation, so these two instructions cannot both hold.
- The design, session-admission delta, timer requirement, remediation note, and Viewer-never-offers scenario all choose the continuous model: only activation or terminal cleanup ends the deadline, and a Viewer that never offers policy must time out (`design.md:46-52`; `specs/sdk-session-admission/spec.md:5-9`; `specs/sdk-active-event-pump/spec.md:297-315`; `reviews/pre-implementation-remediation-round-3.md:7-12`).
- If an implementation follows the contradictory registration-first clause, successful wake assignment invalidates the only deadline before any buffered or future Viewer offer is accepted. A live Viewer that sends no policy can then leave the runner, callback registration, channel, and activation waiter alive indefinitely instead of returning `policyNegotiationTimedOut`.
- Task 4.4 lists registration-before-deadline and activation-versus-deadline races, but it does not explicitly require registration success followed by no policy offer to retain the same token through timeout (`tasks.md:19-22`). A test could therefore encode either side of the contradiction.

**Required remediation**

Replace “registration or activation first” with the intended terminal outcomes, for example: activation or any terminal transition invalidates the exact deadline token; successful wake registration does not replace or cancel it. Keep that same token live while the core consumes buffered policy and waits for a valid initial offer.

Add an explicit deterministic scenario in which registration succeeds, ingress resumes, no valid policy offer arrives, and the original token terminates once with `policyNegotiationTimedOut`. Assert exact callback-token removal, stopped ingress, one waiter result, one channel cancellation, and stale deadline no-op after activation or another terminal winner.

## Round 3 Remediation Verified

- **Pause-aware ingress is implementable.** A lock-owned `running`/`nonterminalPaused`/`stopped` mode can be added orthogonally to the current `drainScheduled` latch. The specified pause-aware take, terminal/overflow bypass, resume authorization, and stop precedence provide exact transitions for every existing `SDKSessionChannelIngress` lock boundary without callback retargeting, lost wake, or paused self-reschedule.
- **Captured-token composition respects target boundaries.** `NearWire` already depends directly on `NearWireFlowControl` in SwiftPM, while CocoaPods compiles Core and SDK sources into the same SPI-hidden module (`Package.swift:44-56`; `NearWire.podspec:33-44`). Making the existing nonthrowing bucket subtraction repository SPI-public is sufficient for cross-target use without adding a product, supported SDK signature, or third-party dependency. The actor receives an explicit nonnegative allowance and cannot commit a larger live prefix; only the exact refreshed copy is installed by a live result.
- **Owner shutdown is level-triggered and ordered.** Registration distinguishes persistent shutdown before assignment; assignment-first shutdown persists unavailable state before its coalesced hint; a pre-result signal remains binding-token-latched; every refresh/drain re-reads availability. This is implementable within the current single NearWire actor and makes empty-live and shutdown outcomes distinct without polling.
- **Earlier architecture/API findings remain closed.** The permanent channel/core/decoder ownership, gate-linearized queue and publication side effects, bounded expiry work, fresh dynamic-policy commit clock, run-cancellation handoff, split committed-prefix accounting, exact origin clock, explicit lifetime handle, policy-consumer ownership, one-shot TTL wakes, and internal-only API/package scope remain mutually consistent.

## Review Status

One unresolved actionable finding remains. Pre-implementation architecture/API closure is not granted until the initial-policy deadline wording and deterministic registration-success/no-offer coverage are corrected and a fresh independent round reports zero unresolved findings.

## Validation

`DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive` passed with `Change 'sdk-active-event-pump' is valid` (exit 0).

`git diff --check -- openspec/changes/sdk-active-event-pump/reviews/pre-implementation-architecture-round-4.md` passed with no output (exit 0). The active OpenSpec change remains untracked as a whole; this review modified no proposal, design, specification, task, production, or test source.
