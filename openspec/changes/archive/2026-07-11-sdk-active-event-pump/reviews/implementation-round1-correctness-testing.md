# Post-Implementation Correctness and Testing Review — Round 1

## Scope

Reviewed the stable post-remediation implementation diff against the active change proposal, design, capability specifications, Tasks 4.4, 5.3, and 6.4, the current documentation and evidence, and the complete active-pump test inventory. The review focused on actor reentrancy, cancellation precedence, token/sequence/bucket commits, frame-decoder boundaries, dynamic policy while work is suspended, queue/heap invariants, backpressure/lost wakes, and deterministic scenario coverage. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Findings

### 1. HIGH — A shutdown signal can be lost while the negotiation owner-refresh Task is completing

**Evidence**

- A signal received during policy negotiation sets `outboundWorkRequested = true` and calls `scheduleOwnerAvailabilityRefreshIfNeeded` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:585-594`).
- The scheduler refuses to start a successor while `ownerRefreshTask` is non-`nil`, and it clears `outboundWorkRequested` when starting the current refresh (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:597-606`).
- On an `.available` result, completion schedules another negotiation refresh only when the observation itself reports `dueWorkRemains`; it does not inspect a signal that relatched `outboundWorkRequested` while the Task was in flight (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:615-638`).
- This creates a concrete actor-reentrancy ordering: an owner refresh observes a live empty owner; `NearWire.shutdown()` then persists shutdown and signals; the signal reaches the core before the prior refresh result, sees the Task still installed, and only relatches the bit; the prior `.available` result then clears the Task and returns without starting a successor. No later edge is required to occur.
- The level-triggered contract requires the pre-result and every later owner signal to cause a persistent availability refresh, and shutdown during negotiation must resolve as `ownerUnavailable` rather than policy timeout (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:170-193`; `openspec/changes/sdk-active-event-pump/specs/sdk-offline-buffer/spec.md:51-55`). The current test covers shutdown with no refresh already in flight, not both result-versus-signal orderings (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:641-656`).

**Impact**

In the losing ordering, a permanently shut down owner remains attached until the policy deadline fires, returning `policyNegotiationTimedOut` instead of `ownerUnavailable` and retaining the channel, waiter, wake registration, owner, and dependencies unnecessarily.

**Required remediation**

When an owner-refresh result clears its token/Task, treat either `outboundWorkRequested` or `observation.dueWorkRemains` as a reason to schedule the next bounded refresh while still negotiating. Add barriers around owner-schedule entry and result delivery and test shutdown-before-result and result-before-shutdown, including an empty observation and coalesced signal storm. Assert exact terminal code, one refresh successor at most, exact wake-token removal, and no retained Task.

### 2. HIGH — A deferred policy transaction can deadlock behind a completed transport-blocked outbound turn

**Evidence**

- A policy offer arriving while `outboundDrainTask` or `incomingPublicationTask` is installed is appended to `deferredPolicyOffers` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1045-1068`).
- A normal drained result calls `applyDeferredPoliciesIfIdle`, and incoming publication completion does the same (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1287-1352,1557-1595`).
- The `.blocked` outbound result instead calls `completeBlockedSchedule`, whose owner/capacity/TTL branches never apply the deferred FIFO (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1296-1301,1355-1385`).
- After that Task has completed, both business schedulers require `deferredPolicyOffers.isEmpty` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1212-1219,1497-1502`). A capacity signal or TTL wake therefore cannot start another outbound turn, and incoming publication is also paused, while no remaining completion path can drain the policy FIFO.
- Task 4.4 requires ordered dynamic transactions during drain/publication and transaction backpressure/overflow; Task 5.3 separately requires dynamic-policy deferral under mailbox backpressure (`openspec/changes/sdk-active-event-pump/tasks.md:22,28`). No current test injects a policy between a blocked turn's actor entry and result delivery.

**Impact**

One valid policy offer at the wrong suspension point can permanently stop policy acceptance and both Event directions without a terminal error. This is a lost-progress deadlock, not merely delayed policy application.

**Required remediation**

Route every live outbound Task completion, including `.blocked`, through one common "both work Tasks idle" policy-commit boundary before scheduling capacity, token, TTL, or incoming work. Policy commit must invalidate the old transport block as specified and preserve FIFO acceptance order. Add deterministic blocked-result barriers for policy-before-result and result-before-policy, unchanged capacity, capacity progress, multiple offers, overflow, and terminal-first cleanup.

### 3. HIGH — Cancellation-first termination observation can be overwritten by terminal cleanup

**Evidence**

- `SDKSessionPullCancellationGate.cancel()` atomically changes a registered gate to `.cancelled` before scheduling its callback (`SDK/Sources/NearWire/Session/SDKSessionAdmissionModels.swift:482-498`).
- The gate now has `closeRegisteredClaim()` for an atomic registered-versus-cancelled winner, but pending termination observation does not use it (`SDK/Sources/NearWire/Session/SDKSessionAdmissionModels.swift:515-527`).
- Terminal cleanup unconditionally changes the pending observer's gate to `.closed` and resumes the stored terminal code (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1826-1829`). If cancellation already changed the gate to `.cancelled` but its actor callback is queued behind terminal handling, cleanup erases that winner; the later cancellation callback finds no pending token and does nothing (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:676-684`).
- The normative scenario requires the private gate to select exactly one winner: terminal-first returns the stored terminal code and cancellation-first returns only `terminationWaitCancelled` (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:9,46-50`). Task 4.4 explicitly requires both observer orderings, but the only active observer test covers final-handle release without per-call cancellation (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:286-319`).

**Impact**

The observer can return a terminal code even though its cancellation gate established cancellation first. That makes the documented one-shot observer result scheduling-dependent and defeats the gate's purpose.

**Required remediation**

Give the gate one atomic close operation that reports the established winner. Terminal cleanup must resume terminal only when it closes a registered claim; if cancellation already won, it must clear the token and complete that call with `terminationWaitCancelled` exactly once, making the queued callback stale. Add explicit barriers for pre-cancel, cancellation-before-terminal, terminal-before-cancellation, stored-terminal-before-wait, and cancellation around registration.

### 4. HIGH — Exactly-at-quantum frames followed by a fragmented frame are rejected as work-limit overflow

**Evidence**

- `WireFrameDecoder.consumeBounded` stops immediately after the configured number of completed frames whenever any input byte remains, returning the unexamined suffix (`Core/Sources/NearWireTransport/WireFrame.swift:173-181`). It does not distinguish a complete additional frame from a partial next prefix or payload.
- The active core maps every nonempty remainder to terminal `activeWorkLimitExceeded` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:746-784`).
- The requirement limits the number of frames *completed* by one receive callback; a callback containing exactly the quantum plus an incomplete next frame has not exceeded that number (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:224-232`).
- The new active test covers exactly two complete frames and then three complete frames with a quantum of two, but not two complete frames plus one byte of the next frame followed by the rest in the next callback (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:493-532`). Task 6.4 explicitly requires fragmentation/coalescing together with the frame-work limit (`openspec/changes/sdk-active-event-pump/tasks.md:35`).

**Impact**

A valid stream whose transport chunk happens to end inside frame `N + 1` is terminated. Correctness therefore depends on receive-chunk boundaries even though framing is required to tolerate arbitrary fragmentation.

**Required remediation**

Return enough decoder state to distinguish "another complete frame is present" from "only a bounded partial frame follows." Retain the partial prefix/payload under the decoder's existing bound and terminate only when the same callback can complete frame `N + 1`. Add boundary tests for every split point in prefix, lane, and payload after exactly `N` frames, plus complete `N + 1`, terminal races, and decoder cleanup.

### 5. HIGH — Active Event byte validation and retention use incompatible units

**Evidence**

- The negotiated `maximumEventBytes` constrains the deterministic JSON bytes of one `WireEventRecord` (`Core/Sources/NearWireTransport/WireEventPayloads.swift:316-326`). Encoding then wraps that body in a version/type/body `WireMessage` and adds the frame prefix and lane (`Core/Sources/NearWireTransport/WireMessage.swift:100-125`).
- Runner cross-limit validation nevertheless estimates the maximum Event send as only `admittedMaximumEventBytes + WireFrameLimits.encodedFrameOverheadBytes`, omitting the deterministic message wrapper (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:466-490`). A transport can therefore pass activation validation but reject a valid near-maximum Event later.
- Incoming validation requires only `maximumIncomingEncodedBytes >= admittedMaximumEventBytes`, but admission charges the entire encoded frame (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:484-490,900-923,948-996`). A valid record at the negotiated limit is charged wrapper/frame bytes beyond that validated limit and can terminate with `activeIngressOverflow`.
- For a batch, the whole frame charge is divided evenly by record count rather than measuring each record's deterministic encoded bytes (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:960-982`). After a small earlier record publishes, a much larger retained record can be substantially undercharged, allowing actual retained record bytes to exceed the configured combined FIFO/in-flight bound.
- The specification requires maximum encoded Event frames to fit transport limits and requires incoming FIFO plus in-flight accounting by deterministic encoded *record* bytes (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:228-230,299-301`). Current active tests have no near-limit encoded Event or heterogeneous batch accounting case.

**Impact**

Validated configurations can fail on protocol-valid Events, and heterogeneous batches can exceed the intended retained-content byte bound after partial publication. Both the transport reservation guarantee and the memory-retention guarantee are unsound at their boundaries.

**Required remediation**

Define and use separate exact units: a conservative/exact maximum fully encoded Event frame for transport cross-limit checks and deterministic per-record byte counts for incoming retained accounting. Compute every batch record charge independently with overflow checks, and keep FIFO plus in-flight charged by those values only. Add exact-bound and bound-plus-one tests for single Events, heterogeneous batches, partial publication, combined FIFO/in-flight pressure, and transport pending/single-send reservations.

### 6. MEDIUM — One downlink continuation can process `quantum + 1` Events

**Evidence**

- `scheduleIncomingWorkIfNeeded` removes up to the full `maximumIncomingPublicationsPerTurn` expired queue entries (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1497-1518`).
- If exactly that many entries expired and the next FIFO head is live, there is no remaining due deadline, so the same invocation continues and selects one additional publication (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1519-1554`). The number of expired IDs is used only for diagnostics, not to compute remaining work allowance.
- The contract says the shared continuation quantum covers publications *or* expiries and permits at most 32/256 total operations per turn (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:259-265`). Task 6.4 requires multi-quantum expiry ordering; the current expiry test contains only one queued Event (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:581-639`).

**Impact**

The actor work bound is exceeded at a precise boundary, weakening fairness and the documented CPU/power limit. With a custom quantum of one, the defect is directly observable as one expiry plus one publication in one continuation.

**Required remediation**

Track the removed count as consumption of the shared turn allowance. Publish only when remaining allowance is positive; otherwise schedule one immediate tokenized continuation. Test `quantum - 1`, `quantum`, and `quantum + 1` expiries followed by a live head at zero and positive rates, including token-later-than-TTL ordering.

### 7. MEDIUM — Wrong Event direction is mapped to `routeMismatch` instead of `sequenceViolation`

**Evidence**

- Incoming validation combines epoch, direction, source, and target in one route guard and maps every failure to `routeMismatch` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:964-972`).
- The closed error contract assigns `routeMismatch` only to epoch or endpoint mismatch and assigns active direction, duplicate, gap, and exhaustion to `sequenceViolation` (`openspec/changes/sdk-active-event-pump/specs/sdk-session-admission/spec.md:74`).
- The current active route test changes the epoch only; there is no direction-specific assertion (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:720-765`).

**Impact**

Callers and internal diagnostics receive the wrong closed code for one explicitly classified protocol failure, and a batch containing a wrong-direction record does not follow the required sequence-error matrix.

**Required remediation**

Check epoch/source/target separately as route validation, then map direction through the sequence-validation path to `sequenceViolation`. Add single and atomic-batch tests for every route component, direction, duplicate, gap, and exhaustion.

### 8. HIGH — The mandatory deterministic matrices remain largely unimplemented

**Evidence**

- Tasks 4.4, 5.3, and 6.4 remain unchecked and enumerate barrier-controlled matrices, not representative smoke cases (`openspec/changes/sdk-active-event-pump/tasks.md:22,28,35`).
- The current active-core inventory adds useful focused cases for activation, one dynamic policy, one uplink prefix, one downlink Event, stable backpressure, frame overflow, diagnostics, negotiation shutdown, one cancellation boundary, and one expiry. It still lacks, among other required cases: observer cancellation winners; registration-success/no-offer and complete deadline orderings; dynamic policy during drain, blocked-result, and publication; zero/fractional/burst token cross-products against service/byte/depth/mailbox bounds; completion-before-block-result; terminal between committed outbound prefix and result; active batch validation/accounting; frame-limit fragmentation; combined FIFO/in-flight overflow; multi-quantum heap churn/expiry; terminal/publication gate winners; and active subscriber isolation.
- Several new concurrency tests still prove quiescence by bounded `Task.yield()` loops rather than a barrier (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:436-484`). Shared helpers poll the wall clock and repeatedly yield (`SDK/Tests/NearWireTests/NearWireTestSupport.swift:237-244`; `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:3207-3214`), while the active uplink test installs a real `Task.sleep` dependency (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:321-360`). This does not satisfy the explicit no-sleeps/probabilistic-scheduling requirement (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:303-305`).
- The focused suites pass, but they do not exercise the unresolved paths above: `SDKSessionAdmissionTests` executed 48 tests with 0 failures; `NearWireBufferTests` plus `WireFrameTests` executed 34 tests with 0 failures.

**Impact**

Passing suites currently establish selected happy paths and a few remediated boundaries, not the change's required correctness envelope. Findings 1–7 are examples of races and exact-bound defects that remain invisible to the present test set.

**Required remediation**

Implement the task matrices with lock/barrier-controlled seams and exact state/byte/token/sequence/Task assertions before checking Tasks 4.4, 5.3, or 6.4. Replace yield-count and wall-time quiescence claims in active-pump tests with observable entry/result/completion barriers. Add a requirement-to-test/evidence table so every normative scenario has a named deterministic test and recorded command result.

## Review Status

**Unresolved finding count: 8 — 6 High, 2 Medium.** Correctness/testing closure is not granted. All findings are actionable and require implementation plus a fresh independent review round.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --filter SDKSessionAdmissionTests`: PASS — 48 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --skip-build --filter 'NearWireBufferTests|WireFrameTests'`: PASS — 34 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check -- openspec/changes/sdk-active-event-pump/reviews/implementation-round1-correctness-testing.md`: PASS with no output.
- Trailing-whitespace scan of this report: PASS with no matches.
