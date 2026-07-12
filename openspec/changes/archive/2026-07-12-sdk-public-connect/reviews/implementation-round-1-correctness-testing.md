# Post-Implementation Correctness and Testing Review — Round 1

## Scope

Reviewed the complete current worktree against the active `sdk-public-connect` proposal, design, capability deltas, and tasks. The review traced the implemented transition gate, public actor slot, Task cancellation, shutdown, core terminal marking, active transfer and connected commit, no-lifetime and lifetime lease release, identity transcripts, connection-limit derivation, stale callbacks, retain graph, and supported-connect integration. No production, test, or specification file was modified.

## Findings

### 1. HIGH — A failed terminal wait can release the lease without terminal evidence

**Evidence**

- `SDKPublicTerminalCoordinator` catches any error from `registration.wait()` and simply returns (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:138-144`). It does not move its still-live lease into `SDKPublicFailClosedLeaseVault`, clear it safely, or retain the coordinator permanently.
- The coordinator stores the lease in an ordinary optional (`SDKPublicConnectionOrchestration.swift:125-137`). When the connected owner or failed attempt later releases the coordinator, `SDKPublicConnectionLease.deinit` invokes release (`SDKPublicConnectionOrchestration.swift:36-59`).
- The specification requires failure to observe terminal to keep the lease fail-closed (`openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:108-112`). The implementation already uses the vault when wait registration fails (`SDK/Sources/NearWire/NearWire.swift:367-389`), but not when the registered wait itself fails.

**Missing scenario**

A registered termination wait throws while the permanent core is still nonterminal, followed by shutdown or connected-owner deinitialization. The test must prove zero release and continuing process contention.

**Recommended fix**

On every `wait()` error, atomically move the lease out of the coordinator into `SDKPublicFailClosedLeaseVault` before the Task completes, deliver no terminal callback, and clear the Task edge. Add an injectable termination-wait failure seam and assert that neither owner destruction nor retry releases or reacquires the lease without terminal evidence.

### 2. HIGH — The required supported-connect production TLS integration does not exist

**Evidence**

- The only public-connect happy-path test injects `SDKPublicSecureDriver` and a synthetic lease probe (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:221-302,721-876`). It proves activation and a terminal state, but not the production Network.framework TLS channel or process lease.
- The existing real-TLS test enters through internal `SDKSessionAdmission`, not `NearWire.connect(code:)` (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:3732-3895`).
- Task 4.2 requires supported connect with deterministic discovery, production secure transport, bidirectional Events, contention until terminal, terminal cleanup, and lease reacquisition only after terminal plus successful synchronization (`openspec/changes/sdk-public-connect/tasks.md:31`). None of the public-connect tests sends an App Event, receives a Viewer Event, competes for the real process lease, or proves post-terminal reacquisition.

**Missing scenario**

One loopback TLS Viewer reached through `NearWire.connect`, one App-to-Viewer Event and one Viewer-to-App Event, a competing instance rejected before terminal, and a later claim succeeding only after terminal cleanup.

**Recommended fix**

Add the specified macOS production-TLS integration with only discovery made deterministic. Enter solely through the supported public method, exercise both Event directions, assert the competitor's fixed public error while the session/core is live, terminate the Viewer, then prove exact release and successful reacquisition with real registry synchronization.

### 3. MEDIUM — Cancellation targets are neither continuous nor notified exactly once

**Evidence**

- Repeated `requestCancellation` calls always invoke the current target callback, even when the same reason was already latched (`SDK/Sources/NearWire/Connection/SDKSessionTransitionGate.swift:86-101`). Public cancellation during admission can call this from both the outer `connect` handler and `SDKSessionAdmission.run`'s handler (`SDK/Sources/NearWire/NearWire.swift:137-143`; `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:77-83`). Admission idempotency can hide duplicate target delivery from driver-level counts.
- After admission returns, the code removes the admission target and suspends at `afterAdmissionResult` and `beforeTerminalWaitRegistration` without installing the returned admitted owner as the successor target (`SDK/Sources/NearWire/NearWire.swift:313-317,343-370`). Similar gaps exist between attachment return and activation-target installation and between active-handle return and its target installation (`NearWire.swift:403-428,442-487`).
- The contract requires target-before-cancellation to receive one request, monotonic exact replacement, and every suspension to retain an authoritative disposable owner (`openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:86-90`).

**Missing scenario**

Cancellation from both nested handlers while one target is installed, plus shutdown/cancellation held at each admission-result, attachment-result, and activation-result barrier. Tests should count target callback invocations directly rather than relying on the idempotent core relay.

**Recommended fix**

Track whether the current generation has already been notified and invoke its callback at most once. Add an atomic `replaceTarget(old:new:cancel:)` operation, using admitted session, attachment, and active handle as continuous successor targets before any post-result suspension. Add both-winner tests for every replacement and stale removal.

### 4. MEDIUM — Task cancellation racing lease claim can return the lease error and start identity work

**Evidence**

- After installing the attempt slot, `performPublicConnect` enters the synchronous lease hook and claim without rechecking the transition gate (`SDK/Sources/NearWire/NearWire.swift:179-185`).
- If Task cancellation latches while the synchronous claim is blocked and claim then throws, both catch branches clear the slot and return the lease error without consulting `transitionGate.currentFailure()` (`NearWire.swift:186-195`).
- If claim succeeds after cancellation latched, the code immediately starts the identity worker and does not recheck cancellation until identity returns (`NearWire.swift:196-229`). The pending-call contract says task-only cancellation before active transfer returns `connectionCancelled` (`openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:7-9,86-90`).

**Missing scenario**

Hold `beforeLeaseClaim`, cancel the connect Task, then test both a throwing claim and a successful claim. The first should return `connectionCancelled`; the second should release without Keychain/identity work if cancellation already won.

**Recommended fix**

Check the gate immediately before claim, use the gate failure when mapping a racing claim error, and recheck immediately after successful claim before starting identity. On post-claim cancellation, run the no-lifetime exact-release path. Add deterministic assertions for error, claim count, identity count, release count, slot state, and retry.

### 5. MEDIUM — The limit formula lacks the required exact, generated, and downstream evidence

**Evidence**

- `WireEventRecord.maximumDeterministicEncodedByteCount` implements a fixed wrapper plus content-bound formula (`Core/Sources/NearWireTransport/WireEventPayloads.swift:100-160`), and the planner derives frame, mailbox, and active limits (`SDK/Sources/NearWire/Connection/SDKPublicConnectionLimitPlan.swift:20-108`).
- The new transport test exercises seven fixed content examples and silently skips any example rejected by validation (`Core/Tests/NearWireTransportTests/WireEventTests.swift:8-31`). It does not generate/property-test valid shapes near the exact content limit.
- The planner test checks independence from buffer accounting and one arithmetic reservation inequality only (`SDK/Tests/NearWireTests/SDKPublicConnectionFoundationTests.swift:75-110`). It does not encode an exact-maximum record/frame through the production codec, test one-over failures in every downstream domain, exercise the planned secure mailbox/active turn/decoder/incoming queue, or provide the required peak-retention audit.
- These are explicit Task 2.4 and evidence requirements (`openspec/changes/sdk-public-connect/tasks.md:10-11,34`).

**Missing scenario**

Seeded generated valid `JSONValue` trees, an exact deterministic-content-limit Event with maximum non-content fields, one-over cases for record/frame/single-send/two-Control reservation/active-turn/decoder/incoming retention, hostile maximum batch and repeated-frame overflow, and a peak-retention accounting artifact.

**Recommended fix**

Add reproducible generated/property coverage using production encoders and assert actual record/frame sizes never exceed the formula. Drive exact and one-over values through each real downstream admission point, not parallel arithmetic. Record the simultaneous-retention audit in the change evidence.

### 6. MEDIUM — The deterministic orchestration and transcript matrix remains materially incomplete

**Evidence**

- The public orchestration suite has 13 tests (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:10-322`). It does not provide the required table of overlapping preflight conditions, Task-versus-shutdown result, delayed admission-result task-versus-terminal chronology, coordinator registration/wait failure, terminal at every public transfer/commit boundary, stale terminal delivery after a newer token, public release-runtime failure, or retry after successful/failed synchronization.
- No public-boundary test injects claim-exit, release-enter, or release-exit failure even though Task 3.9 requires all three plus repeated/stale release (`openspec/changes/sdk-public-connect/tasks.md:25`). The existing low-level lease tests do not verify facade state/error/cleanup behavior.
- The retain test proves only weak `NearWire` disappearance and final release (`SDKPublicConnectionOrchestrationTests.swift:304-322`); it does not weakly audit coordinator, terminal Task, core, channel, live operations, or pairing data as Task 3.8 requires (`tasks.md:24`).
- Identity tests compare the full read dictionary but only spot-check two fields of the add dictionary and do not prove identity access is absent after public lease-claim failure (`SDK/Tests/NearWireTests/SDKPublicConnectionFoundationTests.swift:112-235`; `tasks.md:12-13`).

**Missing scenario**

The complete Task 3.7–3.10 matrix, with exact public error/state, target generation, channel/handle/Task/callback counts, retained-resource weak references, and real release-runtime outcomes.

**Recommended fix**

Build table-driven tests around the existing hooks for every named boundary and both winners. Add public-orchestrator runtime adapters for isolated claim/release failure fixtures, retain-graph probes for every specified owner, exact add-dictionary equality, and a claim-failure test proving zero identity operations. Do not mark Tasks 2.6 or 3.7–3.10 complete until those assertions and evidence exist.

## Review Status

**Unresolved finding count: 6 — 2 High, 4 Medium. Correctness/testing approval is not granted.**

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-cache swift test --filter SDKPublicConnection`: PASS — 21 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-cache swift test`: PASS — 383 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- `git diff --check`: PASS.
