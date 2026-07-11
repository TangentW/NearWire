# Pre-Implementation Correctness and Testing Review — Round 1

Reviewed the complete `sdk-active-event-pump` proposal, design, task plan, and all five capability deltas against the current queue, rate-control, wire, secure-channel, session-core, public-facade implementation, and their tests. The review traced policy activation and reconfiguration, actor reentrancy, cancellation and terminal ordering, queue/sequence/mailbox commit points, backpressure wakeups, inbound atomicity, TTL behavior, token accounting, and deterministic test seams.

## Findings

### HIGH — Terminal tokens cannot stop irreversible work already running on the NearWire actor

**Evidence**

- The design performs mailbox admission and queue removal inside the suspended NearWire drain, then validates the drain token only after the call returns (`design.md:68-82,94-100`). Incoming publication similarly calls `NearWire.publishIncoming` and commits the token only after the call returns (`design.md:112-118`).
- Cleanup only invalidates drain/publication tokens (`design.md:138-144`; `specs/sdk-active-event-pump/spec.md:189-204`). A stale result token can prevent later core mutation, but it cannot undo an Event already admitted to the channel, removed from the queue, counted in telemetry, or published to subscribers.
- The current actor seams demonstrate those irreversible points: `NearWire.drainOutbound` mutates queue identity and telemetry in its callback before returning (`SDK/Sources/NearWire/NearWire.swift:491-529`), and `publishIncoming` calls the event hub before returning success (`SDK/Sources/NearWire/NearWire.swift:437-468`).
- Therefore cancellation or transport terminal input can win on `SDKSessionTransportCore` while an already-running NearWire call continues to admit/remove/publish work afterward. This contradicts the claimed terminal winner and stale-result safety in `specs/sdk-active-event-pump/spec.md:193-204`.

**Required remediation**

Define one shared lock-protected active-operation gate owned by the core but passed into each drain/publication call. Terminal cleanup must close it synchronously. Every irreversible mailbox-admission-plus-queue-removal transaction and publication must claim the same gate while performing its side effect, so either that side effect linearizes before terminal closure and is an explicitly allowed winner, or terminal closure wins and the side effect does not occur. Result tokens remain useful for actor-state ABA protection but are not a substitute for this cross-actor linearization. Add deterministic barriers for terminal-before-claim, claim-before-terminal, terminal between accepted prefix candidates, and terminal while publication is waiting.

### HIGH — Dynamic policy acknowledgement and application are not one ordered transaction across in-flight work

**Evidence**

- The plan defers only uplink bucket reconfiguration while a NearWire drain is suspended, while saying downlink changes apply immediately and every offer receives an acceptance (`design.md:50-57`; `specs/sdk-active-event-pump/spec.md:28-34,54-58`).
- A suspended drain can still be synchronously admitting multiple Event frames from the NearWire actor. If the core admits a policy acceptance before that drain finishes, the channel FIFO can contain old-policy Event, new-policy acceptance, then another old-policy Event. The peer observes the policy boundary before all old-policy work, despite the plan charging the whole drain to the old bucket.
- Downlink has the same reentrancy hole. A publication selected under the old bucket awaits `NearWire.publishIncoming` (`design.md:112-117`). A policy offer can reenter the core and reconfigure the downlink bucket before that publication returns; committing the old publication afterward either charges the new bucket, moves its clock backward, or loses exact token accounting.
- The specification does not state whether Events received after a dynamic offer but before its acceptance remain under the old policy, nor does it define an acceptance/application commit point for both directions.

**Required remediation**

Make each dynamic offer an ordered policy transaction containing the observation time, exact acceptance bytes, and both directional reconfigurations. If an old-policy drain or publication is in flight, defer the entire transaction—including acceptance admission and both bucket changes—until old-policy accounting finishes. State that the old policy remains effective until acceptance is admitted; subsequent offers stay in the same bounded FIFO and are applied one at a time. Alternatively define a generation/snapshot algorithm that proves equivalent mailbox order and old-bucket token commitment, but do not acknowledge a policy while old Event admission can still follow it. Add deterministic tests for offers during a multi-candidate drain, during publication, multiple queued offers, coalesced post-offer Events before acceptance, lower/zero rate changes, response backpressure, and terminal races.

### HIGH — Send completion can be lost before a blocked drain result installs the backpressure latch

**Evidence**

- The plan says mailbox backpressure suppresses producer wakes until the next send completion, policy change, or terminal input (`design.md:94-100`; `specs/sdk-active-event-pump/spec.md:94-122`).
- Because the core awaits the NearWire drain, it is reentrant. A send completion can be processed while the drain is still running, after capacity has become available but before the drain returns `transport-blocked`. The returned result can then install the blocked latch after the only freeing completion was already observed. With no remaining send and producer signals intentionally suppressed, the retained head can stall indefinitely.
- Neither the design nor tasks require a send-progress generation or a deterministic completion-before-block-result scenario.

**Required remediation**

Snapshot a monotonic mailbox-progress generation when a drain starts. Increment it on every relevant send completion. When a blocked result returns, install the block only if the generation is unchanged; otherwise schedule one bounded retry immediately. Preserve the existing coalesced-work flag across this decision. Add a deterministic barrier test in which the capacity-releasing completion is delivered before the blocked result returns and prove exactly one retry with no polling or producer-signal loop.

### HIGH — Zero-rate TTL processing has no wake source in either direction

**Evidence**

- The policy requirement says zero pauses business transfer while queue retention and TTL processing continue (`specs/sdk-active-event-pump/spec.md:30-34`).
- Uplink and downlink scheduling explicitly create no token timer at zero rate (`design.md:94-99,112-118`; `specs/sdk-active-event-pump/spec.md:98-105,157-175`). The only planned uplink signals are new buffered work, shutdown, send completion, policy change, and terminal input. The drain result does not return the next queue deadline.
- A live uplink Event buffered at zero rate can therefore pass its deadline without any actor turn. A downlink FIFO head at zero rate has the same problem: it remains retained after its receiver-local deadline until unrelated input arrives. That contradicts “TTL processing SHALL continue,” “retain Events only within ... TTL bounds,” and the head-expiry scenario.
- Tasks 5.1, 5.3, 6.3, and 6.4 mention token wakes and zero-rate behavior but no one-shot expiration wake or lazy-expiration contract.

**Required remediation**

Define a bounded one-shot expiration wake per direction, not a recurring poll. The NearWire drain/snapshot result must expose the next uplink deadline, and the incoming FIFO already knows its head deadline. A single directional wake token may target the earlier of token availability and expiry; at zero rate it targets expiry only. Expiry turns must service route drops/expired work without consuming business tokens. Alternatively explicitly adopt lazy expiration and remove the stronger TTL-processing claims, but that would weaken current requirements. Add virtual-clock tests for zero-rate expiry, policy changes racing expiry, cleared/replaced heads, stale expiry tokens, and empty queues.

### HIGH — A completed attachment policy pull can consume the initial offer before the runner claims ownership

**Evidence**

- The admission delta addresses only a pull that is still pending when runner start occurs (`specs/sdk-session-admission/spec.md:3-19`). It is internally contradictory about whether claiming rejects/cancels the pull or runner start fails and leaves it untouched.
- The current core removes and returns an immediately buffered policy message before any active runner exists (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:267-297`). Once that pull completes, there is no pending waiter and no FIFO entry. A later active runner can claim successfully but cannot consume the already-returned initial offer; it waits for another offer and can time out despite the Viewer having correctly offered policy.
- No exact error, retry rule, or ownership state is specified for a prior completed pull, a cancelled pull, or runner start racing pull registration.

**Required remediation**

Introduce one irreversible policy-consumer ownership state in the permanent core. The first successful claim must select either attachment-pull mode or active-runner mode. Runner claim must fail deterministically if any pull has already consumed policy, and all pulls must fail deterministically after runner ownership begins; alternatively remove external pull consumption from the attachment transferred to the active pump. Specify the exact closed error and whether a failed runner object is retryable. Reconcile `reject or cancel` with the pending-pull scenario. Add tests for buffered immediate pull before runner, empty pending pull, pre-cancelled/cancelled pull, pull callback racing runner claim, and pull attempts after runner activation.

### MEDIUM — Pre-registration run cancellation has no defined session outcome

**Evidence**

- `run()` is one-shot and a pre-latched cancellation returns `cancelled` without a pump waiter or wake (`specs/sdk-active-event-pump/spec.md:3-20`; `design.md:32-38`).
- The plan says run-task cancellation after registration converges on core terminal cleanup, but does not say whether pre-registration cancellation also terminally cancels the attached session. If it does not, the one-shot pump is consumed while the live attached session has no active runner; if it does, the mechanism and ordering against runner claim are unspecified.

**Required remediation**

Choose and specify one outcome. The consistent one-shot behavior is for a pre-cancelled run to atomically close its gate and request terminal core cancellation without installing a pump waiter/wake. Define its race with core claim and final-handle cancellation, and test cancellation before handler entry, between gate creation and claim, immediately after claim, and after terminal state.

### MEDIUM — The outbound byte turn bound is referenced but never defined or validated

**Evidence**

- The active drain is described as accepting count and byte turn bounds and reporting accepted byte totals (`design.md:68-82`; `specs/sdk-offline-buffer/spec.md:3-7`).
- `SDKActiveEventPumpLimits` defines only outbound candidate count, not outbound bytes per turn (`design.md:120-135`; `specs/sdk-active-event-pump/spec.md:183-187`). The main uplink scheduling requirement likewise specifies only 64/256 candidates.
- The current queue offer API requires a positive `maximumBytes` and uses it to stop fairly without mutation (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:365-438`). The implementation cannot choose or validate the new active byte value from the approved plan.

**Required remediation**

Either add an explicit default/hard outbound encoded-byte turn limit, or define an overflow-checked derived value such as candidate quantum multiplied by the negotiated maximum encoded Event frame and capped by a documented bound. Clarify whether the queue offer bound counts queued draft-accounting bytes or exact encoded wire bytes; route drops must remain outside it. Add boundary and fairness tests for a small byte turn, encoded-size expansion, accepted prefixes, and arithmetic overflow.

### MEDIUM — The required actor-reentrancy tests lack deterministic suspension seams

**Evidence**

- Tasks require no-sleep tests for policy changes during a suspended drain, cancellation during drain/publication, backpressure completion races, publication races, stale work, and terminal cleanup (`tasks.md:22,28,35`).
- The pump is specified to depend on concrete `NearWire` and `SecureByteChannel` instances and inject only clock/sleep behavior (`design.md:32-36`; `tasks.md:19`). Current `NearWire.drainOutbound` and `publishIncoming` are synchronous actor-isolated methods, so tests cannot deterministically hold them at the irreversible boundary without a production seam. Queue depth or `Task.yield()` would only make these races probabilistic.

**Required remediation**

Add explicit internal dependency closures/protocols or lock-controlled test hooks for wake registration/removal, drain entry and candidate admission, publication entry, mailbox admission/completion, and terminal-gate claim. Keep live dependencies fixed to the concrete NearWire/channel operations. Extend tasks 4.4, 5.3, and 6.4 with barrier-controlled race matrices and assertions for task/token counts, exact winners, no late side effects, and no sleeps.

## Additional Verified Areas

- Existing `EventTokenBucket` supports atomic backward-clock failure, pause/resume without manufactured tokens, finite exact next-token delay, and bounded burst behavior, so it is suitable once in-flight policy generations are specified.
- Existing `BoundedEventQueue.offer` preserves candidate ordinal and fairness credit on stop, removes route-preflight work without charging the byte budget, and commits only accepted prefixes. The active drain can build on it after the missing byte-bound and terminal gate contracts are defined.
- Existing wire records establish receiver-local TTL, batch decoding validates basic epoch/direction/contiguous sequence before construction, and a copied active route/sequence plan can provide the stronger all-or-nothing batch commit required by this change.
- Reserved secure-mailbox admission is a proportionate Core extension, and tasks 2.1–2.2 cover its arithmetic, FIFO, concurrency, and terminal boundaries.

## Strict Validation

Command:

```text
openspec validate sdk-active-event-pump --strict
```

Result: PASS — `Change 'sdk-active-event-pump' is valid` (exit 0). The CLI emitted non-gating PostHog network flush warnings after successful validation because telemetry could not reach `edge.openspec.dev` in the restricted environment.
