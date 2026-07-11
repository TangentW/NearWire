# Pre-Implementation Security, Performance, Power, and Documentation Review — Round 2

## Findings

### HIGH — Terminal gating still excludes expiration, route-drop, and scheduling-observation queue mutations

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:70-76,88-96,106-114,167`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:74-80,108-124,243-255`
- `openspec/changes/sdk-active-event-pump/specs/sdk-offline-buffer/spec.md:5-29`
- `openspec/changes/sdk-active-event-pump/specs/bounded-event-queue/spec.md:3-25`
- `Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:370-438,441-486,579-595`
- `SDK/Sources/NearWire/NearWire.swift:491-539`

The shared gate now correctly covers mailbox admission plus accepted-candidate queue/sequence/telemetry commit. However, the same drain removes expired work before candidate callbacks, route preflight may remove a mismatched reply without mailbox admission, and the new scheduling observation removes every due Event before returning the next deadline. Those are irreversible queue, fairness, live-ID, and telemetry mutations, but the current gate contract is written only around an encoded candidate's mailbox transaction and incoming publication.

A drain or TTL observation already queued on the NearWire actor can therefore run after terminal close, expire or route-drop App work, and change selection/statistics even though the terminal-first requirement says queue and telemetry remain unchanged and cleanup does not clear the uplink queue. Core stale-result tokens cannot undo those mutations.

Remediation:

- Require the active-operation gate at every session-owned NearWire mutation boundary: due expiration, route-affinity removal, accepted mailbox commit, live-ID removal, fairness-credit consumption, and associated statistics.
- Do not hold the gate during potentially expensive encoding or a whole 64-MiB/256-candidate turn. Extend the queue offer/scheduling API with a synchronous per-mutation authorization/commit closure, or split plan from mutation, so terminal can close promptly and each small mutation has the same two legal outcomes.
- If expiration is allowed after terminal as ordinary owner maintenance, remove the terminal-first queue-unchanged claim and ensure it is invoked only by a later public queue operation, not by a stale active task. Route drops must remain active-route gated in all cases.
- Add barriers for terminal before/after due expiration, route drop, accepted candidate, and scheduling observation. Assert queue IDs, deadline index, fairness credits, live IDs, all statistics, mailbox bytes, and callback notifications.

### HIGH — Active-owner wake binding is not linearized with terminal cleanup or ingress decoding

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:42-48,60-76,138-140,167`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:5-9,40-70,116-120,239-255`
- `openspec/changes/sdk-active-event-pump/specs/sdk-offline-buffer/spec.md:33-47`
- `openspec/changes/sdk-active-event-pump/tasks.md:13-22,39-44`
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:212-231,346-395`

Wake installation and removal are actor-isolated NearWire calls, but the shared gate is currently specified only for drain/publication side effects. Terminal cleanup can close the gate and enqueue stale-token removal before an earlier registration call has reached the NearWire actor. Removal then observes nothing, while the late registration subsequently installs the singleton callback. Its weak target avoids a core retain cycle, but the stale registration and closure remain in NearWire and can reject the next session's legitimate registration.

The same unbounded actor hop creates a startup ordering problem. The core must preserve the scenario where an initial offer and Event are coalesced, yet Event lane remains terminal before activation. If ingress decoding continues while runner setup is awaiting wake registration, the Event can be decoded under the pre-active phase and fail before the offer can activate it. If activation is allowed first, App queue mutations occurring before callback installation can lose their only wake unless registration returns an atomic initial snapshot.

Remediation:

- Define one explicit `bindingActiveOwner` phase. After runner ownership, pause nonterminal ingress decoding at the existing bounded ingress edge while terminal priority remains live.
- Make NearWire registration one gate-claimed transaction that installs the exact token/callback and returns the initial fair candidate/deadline snapshot. Terminal-first installs nothing; registration-first is followed by exact-token removal. Actor serialization must prove that work before registration appears in the snapshot and work after registration signals the callback.
- Resume ingress only after the current binding token succeeds, then consume buffered/raw bytes in original order so offer acceptance and active phase precede a coalesced Event. Keep the attachment/policy deadline bounded throughout binding.
- Add deterministic tests for remove-before-late-install, terminal-before/after registration claim, send/clear/shutdown during binding, prebuffered work, offer-plus-Event raw ingress during binding, registration failure, and a later session registering on the same NearWire instance.

### HIGH — Late run-task cancellation is not explicitly invalidated before the active handle commits

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:32-38,161-167`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:3-20,231-243`
- `openspec/changes/sdk-active-event-pump/tasks.md:19-22`
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:552-574`

The revised lifetime model correctly returns a separate active handle, but it specifies only pre-registration cancellation and general run-task cancellation before activation. A cancellation handler can race after initial policy acceptance has committed but before or just after the activation continuation resumes. Unless the run token is invalidated before handle ownership and waiter resumption, that stale callback can terminate the newly active session even though the caller received the sole live handle. The admission implementation already demonstrates the necessary ordering by invalidating its attempt token before resuming success.

Remediation:

- Give activation its own reference-identity attempt token. At successful activation, transfer relay ownership to the handle, invalidate the run token, clear the activation waiter, and only then resume `run()`.
- A cancellation that claims the token first must terminally win and return no handle; every cancellation after invalidation must be ignored. From commit onward only the returned handle/relay and independent terminal causes may cancel the session.
- Define the starter's post-success retained state so it no longer owns the attachment, relay, handle, or cancellation token.
- Add exact barriers for cancellation immediately before acceptance admission, after acceptance but before token invalidation, after token invalidation but before waiter resume, and after `run()` returns. Assert one winner, handle lifetime, and at-most-once channel cancellation.

### MEDIUM — “Coalesced” outbound notifications do not yet bound callback-created routing Tasks

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:60-64,106-114,159`
- `openspec/changes/sdk-active-event-pump/specs/sdk-offline-buffer/spec.md:33-47`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:114-124,237-243`
- `openspec/changes/sdk-active-event-pump/tasks.md:13,26-28,43`
- `SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:48-59,62-100,129-139`

The plan says repeated queue notifications coalesce and enumerates the core's drain/wake/publication Tasks, but it does not require coalescing before a weak callback creates a Task that hops to the core actor. A straightforward callback implementation using `Task { await core.signalWork() }` creates one Task per public send, replacement, overflow, clear, expiration, or drain mutation. A producer storm can therefore retain an unbounded number of short-lived Tasks waiting on the core even though their eventual actor work coalesces.

Remediation:

- Add a lock-protected outbound-signal ingress analogous to `SDKSessionChannelIngress`. The callback must atomically change idle-to-scheduled before creating one weak-routed Task; further signals set only a dirty/coalesced bit.
- On completion, atomically schedule at most one successor when dirty. Terminal cleanup must stop the ingress, release its closure/token, and make every late signal a no-op.
- Include this routing Task explicitly in the task/retention inventory, separate from the actor-owned outbound drain and decision wake.
- Add a concurrent signal-storm test proving one scheduled routing Task, at most one successor, no strong core edge, no lost work, and zero retained callbacks/Tasks after terminal state.

### MEDIUM — The “bounded” downlink deadline index has no concrete node or compaction invariant

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:120-134,146-159`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:160-199,231-239`
- `openspec/changes/sdk-active-event-pump/tasks.md:32-35,43`
- `Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:190,557-595,675-700`

The incoming FIFO count and bytes, in-flight publication, decoder partial bytes, callback ingress, and per-subscriber buffers are now correctly separated for audit. The additional deadline index is only described as bounded. A conventional lazy min-heap accumulates stale nodes whenever publication removes Events whose deadlines are not currently minimum; over a long active session its memory can grow with lifetime traffic rather than the 10,000 retained-Event maximum unless an exact rebuild rule exists. Rebuilding too often can instead create an avoidable O(n) power cost.

Remediation:

- Specify an indexed heap with at most one deadline node per charged Event, or define an overflow-safe stale-node threshold and deterministic rebuild invariant, such as a fixed constant plus a small multiple of combined retained count.
- Charge or independently report the index's node storage in the retention audit, clear it on terminal state, and ensure in-flight transfer/removal cannot leave a live duplicate node.
- Bound rebuild work or account it within a named turn quantum so a hostile TTL pattern cannot monopolize the core actor.
- Add long-churn tests with nonmonotonic TTL order, publication, expiration, batch admission, policy pause, and terminal cleanup. Assert maximum node count, rebuild count/work, exact earliest deadline, and zero retained nodes after cleanup.

## Round 1 Remediation Verified

- Accepted Event publication and mailbox-plus-queue commit now share a synchronous active-operation gate with terminal state; core result tokens are correctly treated only as stale-result protection.
- Dynamic offers are complete bounded bidirectional transactions. Acceptance and both bucket changes wait for old-policy drain/publication token commitment at captured selection times, and no Event selection crosses an acceptance boundary.
- Both directions use one token-or-TTL decision wake. Zero rate schedules only finite deadline work, and downlink rechecks TTL at the NearWire publication boundary.
- Incoming retained count/bytes now combine FIFO and in-flight publication; decoder partial storage, callback ingress, and public subscriber buffers remain explicitly separate for documentation and evidence.
- Secure mailbox snapshots, progress generation, known-size predicates, post-result re-snapshot, candidate identity probes, and repeated-small-completion tests close the lost-wake and blocked-event re-encoding/power gaps without retaining encoded payloads.
- The starter/active-handle/termination-observer split breaks the prior pending-run relay cycle. Policy consumer ownership and exact pull/runner errors are now irreversible and explicit. Outbound count/byte turns and deterministic barrier dependencies are also defined.
- Capability and phase checks, hostile diagnostic redaction, inherited mandatory TLS with no delivery/authentication overclaim, queue non-delivery semantics, public stream overflow isolation, SwiftPM/CocoaPods invisibility, and the validation/evidence/documentation plan remain proportionate and complete.

## Validation Performed

- `openspec validate sdk-active-event-pump --strict`: passed. Optional PostHog telemetry flush failed because network access was unavailable and did not affect validation.
- Static re-review of the complete current proposal, design, task plan, six capability deltas, every Round 1 review/remediation report, relevant canonical specifications, current bounded queue/deadline heap, secure mailbox and callback ingress, permanent session core/relay/decoder, wire Event and sequence models, rate bucket, NearWire queue/publication seams, public stream hubs, diagnostics, and SwiftPM/CocoaPods boundaries.
