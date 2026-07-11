# Pre-Implementation Correctness and Testing Review — Round 2

Re-read the complete current proposal, design, task plan, six capability deltas, all Round 1 reviews, and the Round 1 remediation summary against the existing queue, rate, wire, secure-mailbox, session-core, callback-ingress, public-stream, drain, and publication code and tests. Round 1 remediation substantially closes the previously reported policy, backpressure, TTL, retention, policy-consumer, lifetime, byte-bound, and deterministic-test gaps. The findings below are the remaining or newly exposed issues in the revised plan.

## Findings

### HIGH — Wake registration is not terminal-linearized, and startup has no binding phase that preserves initial wire order

**Evidence**

- Pump start installs one NearWire wake registration across an actor suspension, and terminal cleanup later unregisters the matching token (`design.md:60-66,167`; `specs/sdk-active-event-pump/spec.md:114-122,243`). The shared operation gate is explicitly applied to candidate commit and incoming publication, not registration (`design.md:68-74`; `specs/sdk-offline-buffer/spec.md:49-61`).
- Terminal can therefore remove a token before an outstanding registration call executes. A stale registration result may then install the callback after cleanup, leaving NearWire with an orphaned registration that can reject the next session's “exactly one” registration. Result-token invalidation cannot undo a callback already stored on the NearWire actor.
- Startup ordering is also undefined. If the core awaits registration before consuming a buffered initial offer, the permanent ingress remains reentrant. An Event arriving after that already-buffered offer can still hit pre-active lane rejection before the offer is processed, contradicting the buffered/coalesced activation contract (`design.md:42-48`; `specs/sdk-active-event-pump/spec.md:40-70`). If the offer activates first, `run()` can return a handle and start Event work before wake registration and the prebuffered-queue drive are installed.
- `SDKActiveEventPumpDependencies` provides barriers around wake install/removal, but the artifacts define no gate-claimed registration result or ingress-paused binding state (`design.md:136-140`; `tasks.md:19-22`).

**Required remediation**

Add an explicit `bindingOwner` stage before policy activation. Generate the wake token before suspension and make NearWire registration claim the shared active gate around the actual callback install. Terminal-first must install nothing; registration-first must complete before gate close can proceed, after which exact removal is ordered after installation. While binding is suspended, pause nonterminal ingress decoding in the bounded existing ingress while preserving terminal priority. After registration succeeds, process the pre-existing policy FIFO first, then resume queued ingress so an offer already before an Event activates it in wire order, and perform the initial outbound schedule drive before returning the active handle. Add barrier tests for remove-before-install, install-before-terminal, terminal during binding, buffered offer plus Event during binding, no-offer Event, prebuffered uplink work, and a later session registering after cleanup.

### HIGH — Activation commit does not explicitly invalidate run-task cancellation before returning the lifetime handle

**Evidence**

- The starter's task cancellation terminates the core before activation, while successful activation returns a lifetime handle whose own relay becomes the cancellation authority (`design.md:34-40`; `specs/sdk-active-event-pump/spec.md:3-9`).
- The admission error delta says a stale active-run token is ignored after invalidation (`specs/sdk-session-admission/spec.md:48`), but the active-pump design never defines that token's installation, invalidation, or ordering against activation-waiter resumption.
- If exact activation and `Task.cancel()` race, an `onCancel` callback scheduled just after the core resumes `run()` can still reach the core after the handle is committed and cancel the newly active session. The returned handle then does not own the lifetime it was promised. The current task matrix mentions task cancellation and deadline races but does not require the critical cancellation-after-commit barrier (`tasks.md:19,22`).

**Required remediation**

Give each activation attempt one reference-identity run token captured by its cancellation gate. On successful initial-policy commit, invalidate that token before resuming the activation waiter or exposing the handle. A cancellation bearing the old token after commit must be ignored; only handle/relay cancellation may terminate afterward. Cancellation processed before commit must win terminally and return no handle. Add deterministic tests for cancellation before runner claim, during binding, during initial acceptance admission, immediately before commit, after token invalidation but before waiter scheduling, and after the handle is returned.

### MEDIUM — Uplink expiry observation bypasses the advertised turn quantum

**Evidence**

- The active uplink turn is bounded to 64/256 candidates, and route drops and expiration are stated to count toward queue service (`design.md:104-110`; `specs/sdk-active-event-pump/spec.md:114-124`).
- The new queue scheduling observation instead removes *every* event already due before returning the next deadline (`specs/bounded-event-queue/spec.md:3-19`). A valid configured queue can hold 10,000 Events (`Core/Sources/NearWireFlowControl/EventQueueConfiguration.swift:41-63`).
- Consequently one zero-rate TTL wake or cheap fair-candidate probe may synchronously expire all 10,000 entries on the NearWire actor, exceeding the active turn quantum by almost forty times and delaying other NearWire operations. The revised tasks request high-depth and zero-rate tests but do not define an expiry quantum or continuation (`tasks.md:13-15,26-28`).

**Required remediation**

Make queue scheduling expiration explicitly bounded by a supplied service quantum. Return whether due expirations remain plus the next deadline; if due work remains, schedule one coalesced immediate continuation rather than looping without an actor boundary. Count route removals and expirations against the same candidate-service budget used by active draining, or define a separate positive hard-bounded expiry quantum consistently in limits/specs. Add 10,000-item same-deadline tests proving per-turn limits, exact statistics/IDs, prompt terminal/cancellation progress, and no recurring timer.

### MEDIUM — Candidate-gate and captured-token contracts disagree for a committed prefix when terminal wins before drain return

**Evidence**

- Candidate commit occurs on the NearWire actor under the shared gate, while uplink token consumption occurs later on the core actor after the drain returns at the captured selection time (`design.md:68-90,104-112`).
- The normative requirement instead includes “consume one uplink token” in the gate-winning candidate transaction (`specs/sdk-active-event-pump/spec.md:72-80`). That token bucket is core-actor state and cannot be synchronously mutated by the NearWire candidate transaction.
- In a multi-candidate drain, candidate 1 may commit before terminal, terminal may close the gate before candidate 2, and the outer drain result may return after core cleanup has invalidated its token. The queue/mailbox/telemetry prefix is committed, but no artifact defines whether its core sequence/token result is recorded, deliberately discarded because the session is terminal, or stored in shared gate state. “Record any committed-before-terminal result” (`design.md:108,167`) is not implementable from a stale return after active state has already been released.

**Required remediation**

Separate the contracts precisely. The gate-linearized NearWire transaction should cover mailbox bytes, queue removal, local planned sequence progression, and telemetry. Core token consumption and adoption of the returned counter should occur only for a still-live matching drain result at the captured time; if terminal closes after an accepted prefix, specify that the terminal session deliberately discards bucket/counter state because it cannot send again while preserving the already committed local-acceptance telemetry. Alternatively store a constant-size committed-prefix receipt in the shared gate that terminal cleanup consumes before releasing active state. Add a deterministic three-candidate test with commit-before-terminal, terminal-between-candidates, and terminal-first outcomes, asserting mailbox bytes, queue IDs, telemetry, sequence result, token snapshot, result-token handling, and exactly where iteration stops.

### MEDIUM — Observer cancellation and terminal/ownership precedence remain under-specified

**Evidence**

- The one-shot termination observer defines `terminationWaitCancelled` for task cancellation and stores exact terminal state for a later first wait, but does not say which outcome wins when cancellation and terminal completion race after registration (`design.md:36-40,161-167`; `specs/sdk-active-event-pump/spec.md:9,34-38`; `specs/sdk-session-admission/spec.md:44-48`). Without a pull-style synchronous gate and exact precedence, an implementation can double-resume or return different errors based on Task scheduling.
- Policy-consumer ownership is now irreversible and covers completed/cancelled pulls, but runner precedence after terminal remains ambiguous. The runner rule says pull ownership yields `policyConsumerClaimed`, while the general terminal rule says activation, termination, and every later internal operation observe the exact stored terminal code (`specs/sdk-session-admission/spec.md:5-9,44-48,65-69`). The artifacts do not state whether terminal or prior pull ownership wins for a runner attempted after both exist.
- The task plan asks broadly for non-owning wait and every pull/runner race but does not enumerate these compound outcomes (`tasks.md:20-22`).

**Required remediation**

Specify a private lock-protected cancellation gate for each observer wait, with the same exact-once claim/close discipline as policy pulls. Define terminal-versus-observer-cancellation precedence, cancellation before registration, terminal before registration, and cancellation after immediate stored-terminal return. Separately define runner inspection order: pre-latched run cancellation, stored terminal, policy-consumer ownership, and second-run state, or another explicit order. Add compound matrix tests for terminal plus pull ownership, pending pull plus terminal plus runner, observer cancellation plus terminal, second observer wait after each first outcome, handle deinit while observer cancellation is queued, and stored-terminal observation after handle release.

## Round 1 Findings Verified Closed

- Complete dynamic policy transactions now defer acceptance and both bucket changes until old drain/publication work consumes tokens at captured selection times; post-offer Events remain buffered until the transaction commits (`design.md:50-57`; `specs/sdk-active-event-pump/spec.md:40-70`).
- Completion-before-block-result now re-snapshots capacity, known-size predicates prevent repeated expensive encoding, mailbox progress is generation-tagged, and fair-candidate probes preserve scheduler credits (`design.md:94-116`; `specs/secure-byte-channel/spec.md:7-56`; `specs/bounded-event-queue/spec.md:26-34`).
- Zero-rate token-or-TTL decision wakes exist in both directions. Downlink uses an all-FIFO deadline index and rechecks an in-flight publication's TTL immediately before gated publication (`design.md:104-134`; `specs/sdk-active-event-pump/spec.md:193-223`).
- Incoming count/byte accounting now includes the separately retained in-flight publication until publication, expiry, or cleanup, while decoder, ingress, and subscriber bounds are explicitly separate (`design.md:118-134`; `specs/sdk-active-event-pump/spec.md:160-199`).
- Pull/runner ownership now persists across immediate and cancelled pulls, preserves pre-cancelled precedence, and blocks post-runner pulls with a closed code (`design.md:42-48`; `specs/sdk-session-admission/spec.md:3-39`).
- The starter/handle/observer split removes the original pending-run retain cycle; outbound byte limits and barrier-capable dependencies are explicit (`design.md:32-40,136-159`; `tasks.md:19-35`).

## Strict Validation

Command:

```text
openspec validate sdk-active-event-pump --strict
```

Result: PASS — `Change 'sdk-active-event-pump' is valid` (exit 0). The CLI emitted non-gating PostHog network flush warnings because telemetry could not reach `edge.openspec.dev` in the restricted environment.
