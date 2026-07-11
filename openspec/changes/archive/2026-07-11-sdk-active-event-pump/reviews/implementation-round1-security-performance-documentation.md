# Post-Implementation Security, Performance, and Documentation Review — Round 1

Reviewed the complete current implementation diff, all seven capability deltas, active-pump documentation, validation scripts, five evidence artifacts, focused and package test inventories, packaging gates, and terminal/resource ownership paths. No production or test source was modified by this review.

## Findings

### 1. HIGH — Transport backpressure creates an immediate Task/actor polling loop while tokens remain available

**Evidence**

- After a drain reports backpressure, the core stores `drain.transportBlock`. When the known candidate still cannot fit, it falls through to `scheduleOutboundDecision` with `eligibleWorkRemains` and the candidate deadline (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1274-1308`).
- The later blocked fast path performs another queue scheduling observation. If capacity is still insufficient and the same fair candidate remains, it again calls `scheduleOutboundDecision` with `eligibleWorkRemains: true` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1314-1343`).
- Because a rejected candidate consumes no token, the bucket commonly still has a whole token. `delayUntilNextTokenNanoseconds` therefore returns zero; `scheduleOutboundDecision` treats zero as an immediate new drain rather than installing a sleep (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1355-1387`). The next drain sees the same block and insufficient capacity, performs another actor observation, and repeats indefinitely until capacity or queue identity changes.
- This directly violates the normative requirement that whole-token availability is not a wake reason while transport-blocked and that capacity progress remains event-driven (`specs/sdk-active-event-pump/spec.md:180-182`). It also contradicts the no-poll power claim in `Documentation/SDK-Active-Event-Pump.md:35,64` and `evidence/ownership-resource-audit.md:36-48`.
- No active-core test holds a stable rejected candidate with positive tokens and insufficient mailbox capacity while asserting that drain/observation/Task counts remain unchanged until a send completion, queue-selection change, policy change, terminal event, or TTL deadline.

**Impact**

Ordinary slow transport or a Control-filled mailbox can cause an unbounded sequence of short-lived Tasks and NearWire actor observations. The candidate is not re-encoded, but the loop can continuously consume CPU and battery on the phone, contend with cancellation and Control handling, and persist for the candidate's full TTL.

**Required remediation**

Give outbound decision scheduling an explicit transport-blocked mode. While the stable block remains insufficient, exclude token availability entirely and schedule only the candidate's TTL deadline; rely on send-completion capacity progress, queue-selection change, policy/route/channel change, owner loss, or terminal input for other retries. Add lock-controlled tests with positive/burst tokens and a stable insufficient mailbox proving no successor drain or observation is created before one authorized wake, plus separate completion-before-result, TTL-first, queue-change, policy-change, owner-loss, and terminal cases. Update the documentation wording so token availability is described as a wake only when no transport block is active.

### 2. HIGH — The completed-frame quantum does not fail closed and permits large hostile continuation chains

**Evidence**

- The normative active-pump requirement says a receive callback that exceeds 256 completed frames by default or 1,024 at the hard maximum must terminate with `activeWorkLimitExceeded` (`specs/sdk-active-event-pump/spec.md:224-232`).
- `WireFrameDecoder.consumeBounded` instead returns all bytes after the quantum as a new `Data` remainder (`Core/Sources/NearWireTransport/WireFrame.swift:88-93,173-191`).
- The permanent core appends that remainder to `activeDecodeBacklog`, creates an `SDKActiveDecodeToken` Task, copies the complete retained backlog into the next turn, and repeats until all bytes are decoded (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:679-763`). No frame-quantum path produces `activeWorkLimitExceeded`; the only production throw of that code is deferred-policy-count overflow (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1017-1025`).
- The implementation can also accumulate later callbacks into the backlog while one remainder exists. When a continuation moves the backlog into its local `bytes`, that local unprocessed storage is temporarily outside `activeDecodeBacklog.count`, so per-Event queue admission does not include it in the active byte calculation (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:729-763,911-965`). This weakens the claimed retained-remainder accounting and can transiently retain the original buffer plus a copied remainder.
- The only new decoder test verifies primitive remainder continuation, not active-session termination or cumulative Task/memory behavior (`Core/Tests/NearWireTransportTests/WireFrameTests.swift:53-70`). The active-pump documentation explicitly documents continuation rather than the approved fail-closed behavior (`Documentation/SDK-Active-Event-Pump.md:39-45`), and `evidence/active-pump-focused.md:21-26` cites that primitive test as coverage.

**Impact**

A peer can coalesce a large number of small valid Control frames and make one bounded callback generate hundreds or thousands of sequential continuation Tasks at the hard byte limit instead of terminating at the declared frame-work boundary. Actor yielding prevents one monolithic turn, but it does not enforce the promised hostile-work limit and increases CPU, allocation, and battery cost.

**Required remediation**

Implement the approved contract: when a single callback contains bytes beyond its completed-frame quantum, terminate once with `activeWorkLimitExceeded`, retain no remainder, and release decoder/ingress/session work through normal cleanup. Add active-core tests for exactly-at-limit, one-over-limit, fragmented final frame, Control-only floods, Event floods, terminal racing the boundary, and cleanup/accounting. If continuation is intentionally preferred, first revise the OpenSpec design and requirements through a new reviewed change and define a cumulative per-callback identity, byte/task bound, transient-memory accounting, and terminal policy; the current documentation and evidence must not silently override the active specification.

### 3. MEDIUM — Owner shutdown during policy negotiation is not level-triggered into terminal cleanup

**Evidence**

- An outbound callback received before or during binding sets `outboundWorkRequested` and calls `scheduleOutboundDrainIfNeeded` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:562-568`).
- The scheduler immediately returns unless state is `.active` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1177-1183`). A shutdown callback delivered after successful registration but before policy activation therefore performs no owner-availability read.
- Successful binding changes state to `.negotiatingPolicy`, resumes ingress, and consumes buffered policies, but it ignores both the registration schedule snapshot and any latched outbound-work signal for an immediate level-triggered refresh (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:525-559`).
- The requirement explicitly says owner shutdown during policy negotiation must terminate with `ownerUnavailable` without waiting for policy timeout or unrelated producer input (`specs/sdk-active-event-pump/spec.md:170-193`). The offline-buffer scenario also requires a shutdown signal between assignment and binding-result delivery to force a matching refresh (`specs/sdk-offline-buffer/spec.md:51-55`).
- Queue-level tests cover registration/shutdown ordering, but no active-core test shuts the owner down after assignment while the Viewer withholds the initial policy offer. Task 5.3 still lists owner shutdown in policy/empty/zero-rate/active states as incomplete (`tasks.md:24-28`).

**Impact**

The App can shut down its bound NearWire owner while the secure session remains in policy negotiation, yet the channel, wake registration, activation waiter, and dependencies remain alive until the policy deadline or a later activation attempt. The terminal result may incorrectly become `policyNegotiationTimedOut` rather than `ownerUnavailable`, delaying cleanup for up to the configured 120-second hard maximum.

**Required remediation**

Route every outbound hint through a coalesced level-triggered availability refresh that is valid during binding and policy negotiation, not only through the active drain scheduler. A binding-token hint that precedes result delivery must be consumed immediately after the matching live result. Add deterministic shutdown-before-assignment, assignment-before-result, post-result/no-offer, active-empty, zero-rate, transport-blocked, and publication-in-flight tests asserting exact `ownerUnavailable` precedence, wake-token removal, stopped ingress, at-most-once channel cancellation, and no retained routing Task or dependency closure.

### 4. HIGH — Required integration, hostile-work, and spec-to-evidence gates are still incomplete

**Evidence**

- Tasks 4.1 through 7.7 remain unchecked, including the complete active ownership/race matrix, blocked retry and power cases, frame-work limit, incoming bounds, production active TLS integration, API/boundary proof, documentation, complete evidence mapping, post-implementation review-to-zero, and archive audit (`tasks.md:17-45`).
- `evidence/active-pump-focused.md:13-30` records broad suite counts but only a small set of active-core scenarios. There is no test for the blocked positive-token no-spin invariant, over-quantum active callback termination, owner shutdown during negotiation, registration-success/no-offer cleanup, dynamic policy across both simultaneous in-flight directions, terminal/publication gate order, combined backlog/FIFO/in-flight hard-byte pressure, or the full cancellation/observer matrix required by Tasks 4.4, 5.3, and 6.4.
- The recorded production TLS test is admission-only. It returns an admitted session and immediately cancels it without attaching or running the active pump (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1952-2065`). `evidence/validation-gates.md:10-19` accurately calls it a production TLS admission filter, but Task 7.1 requires policy activation, bidirectional Events, transport backpressure, and terminal teardown over the production secure channel.
- `evidence/ownership-resource-audit.md` is a useful narrative inventory, but there is no requirement-to-evidence mapping with exact test/command ownership for every scenario, no API inventory artifact, and no recorded proof for the decoder continuation and blocked scheduling claims that the audit labels bounded/no-poll (`evidence/ownership-resource-audit.md:19-54`; Task 7.5).

**Impact**

The passing package, CocoaPods, formatting, boundary, and admission-TLS gates establish compilation and broad regression health, but they do not establish the active pump's security and power contracts. The three implementation defects above survive all recorded runs, demonstrating that current evidence is insufficient for task completion or archive.

**Required remediation**

Keep Tasks 4 through 7 incomplete. After fixing actionable code findings, add the full deterministic matrices named by the task plan, a production TLS active-pump integration covering both directions/backpressure/teardown, exact API and dependency inventory, task/timer/power and transient-retention measurements or assertions, hostile diagnostic coverage, and a requirement-to-evidence table linking every normative scenario to a command and test. Rerun every validation gate from a clean state, record exact results, then perform fresh independent review rounds until all dimensions report zero unresolved findings.

## Verified Controls Without Findings

- Reserved secure-mailbox count/byte arithmetic, zero-reservation compatibility, advisory capacity checks, completion progress, terminal admission closure, and two-Control Event reservation are lock-linearized and have focused concurrency tests.
- Accepted uplink prefixes are bounded by captured whole tokens; route/sequence/TTL construction occurs before admission; mailbox-plus-queue removal is terminal-gated; errors map to closed local codes without underlying text.
- Incoming Event route, sequence, batch atomicity, FIFO/deadline index, TTL recheck, and terminal-gated publication are bounded in the implementation, subject to the decoder-quantum and missing-matrix findings above.
- Active diagnostic descriptions and reflection are code-only; no logging of pairing data, endpoints, route IDs, Event content, wire bytes, certificates, peer text, or underlying transport errors was introduced.
- The active path reuses the admitted mandatory TLS channel. SwiftPM, CocoaPods, strict-concurrency, dependency isolation, implementation-type sealing, and static boundary gates have recorded passing runs.

## Validation Performed During Review

- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check`: PASS with no output before this report was added.

## Unresolved Count

**4 unresolved findings: 3 High, 1 Medium.** Post-implementation security/performance/documentation closure is not granted.
