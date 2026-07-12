# SDK Public Connect Implementation Review — Round 1 Security, Performance, and Documentation

## Scope

This review examined the stable current worktree against the active `sdk-public-connect` proposal, design, capability specifications, and task plan. The review focused on Keychain behavior, pairing and metadata retention, safe public errors, TLS claims, bounded resource planning, terminal lease ownership, package linkage, English documentation, and requirement-to-evidence coverage. No production, specification, or task file was modified by this review.

## Result

Six actionable findings remain: one High-severity implementation issue, one High-severity validation/release-gate issue, two Medium-severity contract or evidence issues, and two Low-severity precision/documentation issues. The TLS 1.3 and unauthenticated-Viewer documentation is otherwise appropriately qualified, public error messages are content-safe, and both SwiftPM and CocoaPods explicitly attach `Security.framework` only to the SDK target/subspec.

## Findings

### 1. High — A failed terminal wait can release the process lease without terminal evidence

**Evidence**

- `SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:36-59` makes `SDKPublicConnectionLease.deinit` call `release()`.
- `SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:125-151` stores the lease in `SDKPublicTerminalCoordinator`, but the coordinator Task simply returns when `registration.wait()` throws.
- `SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:62-76` already provides a permanent fail-closed vault, but the wait-failure branch does not use it.
- `SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:350-365` and `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:715-755` show that the wait is throwing and can produce `terminationWaitCancelled`; this is not a non-throwing type-level invariant.
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:108-114` requires the coordinator to own the sole wait and says failure to observe terminal must keep the lease fail-closed.
- `openspec/changes/sdk-public-connect/tasks.md:21-25` requires one-wait/release race coverage and injected fail-closed lease tests.

**Impact**

The catch branch has no terminal code and therefore no proof that the permanent core is terminal. Once the completed Task releases its captures and the connected owner or coordinator is destroyed, the coordinator's stored lease can deinitialize and invoke release. That can make process ownership available while the original core may still be live, permitting two sessions and defeating the single-Viewer safety boundary. Leaving `task` uncleared is not a valid fail-closed mechanism because completed-Task capture retention is not an ownership contract.

**Recommended fix**

On every `registration.wait()` failure, atomically remove the coordinator's lease and place it in `SDKPublicFailClosedLeaseVault` before the Task ends; do not invoke terminal delivery or ordinary release. Add a deterministic injected wait-failure test that drops every other owner, proves the release callback remains zero, and proves a competing process lease claim remains contended. Also assert that the successful terminal path still releases exactly once.

### 2. Medium — Source-level pairing-code lifetime does not establish the promised immediate reference release

**Evidence**

- `SDK/Sources/NearWire/NearWire.swift:137-148` keeps the raw `code` argument in async public and private call frames for the duration of the attempt.
- `SDK/Sources/NearWire/NearWire.swift:161-166` creates the normalized optional, while `SDK/Sources/NearWire/NearWire.swift:266-289` copies it into immutable `retainedPairingCode`, constructs admission, and clears only the optional. The copied value remains lexically scoped across later suspensions.
- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:119-146` similarly binds an immutable local `pairingCode`, clears the actor property after constructing discovery, and then suspends while the local remains in the function scope.
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:77-84` promises reference release immediately after each ownership transfer, rather than merely eventual release or redacted reflection.
- `openspec/changes/sdk-public-connect/tasks.md:23-24` requires retention tests proving no Task, coordinator, core, live operation, channel, or callback retains pairing data. The current public orchestration tests contain no pairing-retention assertion.

**Impact**

The implementation clears two stored optionals, but copied `PairingCode` values can share the same array storage and remain part of async frames. ARC may shorten their lifetime in a particular optimized build, but the current source does not make the documented immediate-release guarantee robust across build modes and compiler changes. The pairing code is documented as public discovery metadata rather than a password, so this is a retention-minimization contract failure rather than an authentication break.

**Recommended fix**

Move each transfer into a narrow synchronous take-and-construct helper whose frame ends before the next suspension and which clears the owning optional in all paths. Avoid immutable normalized-code bindings in the long-lived async attempt/admission frames. Add an instrumented retention probe or equivalent compiled retain-graph evidence at the admission-construction and discovery-construction barriers, including cancellation and terminal races.

### 3. Low — The advertised Event-record maximum is conservative, not the specified exact valid maximum

**Evidence**

- `Core/Sources/NearWireTransport/WireEventPayloads.swift:100-145` describes an exact V1 record maximum but constructs both source and target roles as `viewer`.
- `Core/Sources/NearWireCore/Event/EventMetadata.swift:91-124` requires every valid direction to contain one App endpoint and one Viewer endpoint; `viewer` is three bytes longer than `app`.
- `Core/Sources/NearWireCore/Event/EventEnvelope.swift:43-45` enforces that relationship in production Event construction.
- `Core/Tests/NearWireTransportTests/WireEventTests.swift:8-33` checks only `actual <= maximum`, and `Core/Tests/NearWireTransportTests/WireEventTests.swift:397-431` constructs the valid one-App/one-Viewer shape. It therefore cannot detect the three-byte overestimate.
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:29-33` requires an exact non-content V1 maximum and least-privilege downstream limits, while `openspec/changes/sdk-public-connect/tasks.md:10-11` requires exact and one-over proof.

**Impact**

The current formula does not under-allocate, but it advertises and propagates a network, frame, decoder, incoming-retention, and transport capacity that is three bytes larger than any valid record can require. The immediate memory impact is negligible, but the implementation and its “exact” documentation do not satisfy the reviewed least-privilege contract.

**Recommended fix**

Build the maximum wrapper with one App role and one Viewer role in a direction-valid shape. Add an exact-equality test using the true maximum valid non-content fields and a maximum-size validated content value, plus downstream exact/one-over tests for wire payload, frame, single-send, pending-send, decoder, and incoming-retention limits.

### 4. Medium — Keychain transcript tests do not prove the exact add dictionary or all forbidden-write guarantees

**Evidence**

- `SDK/Sources/NearWire/Connection/SDKInstallationIdentity.swift:134-155` currently defines the intended exact read and add attribute sets.
- `SDK/Tests/NearWireTests/SDKPublicConnectionFoundationTests.swift:112-130` compares every read dictionary exactly.
- `SDK/Tests/NearWireTests/SDKPublicConnectionFoundationTests.swift:132-151` checks only the add count, accessibility, and value data; it does not compare the full add dictionary, so adding a synchronizable key, access group, access control, label, comment, or other forbidden attribute would not fail this test.
- `SDK/Tests/NearWireTests/SDKPublicConnectionFoundationTests.swift:167-235` verifies bounded read/random/add counts but does not record explicit update/delete counters or bridge the abstract attribute keys to the live `Security` constants.
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:59-75` and `openspec/changes/sdk-public-connect/tasks.md:12-13` require exact production-equivalent dictionaries and transcript evidence for no update/delete behavior.

**Impact**

The reviewed production dictionary is currently least-privilege, and the operations protocol exposes no update/delete method. However, the regression suite does not prove the full security contract it claims to protect. A future accidental attribute expansion could enable synchronization, sharing, UI/authentication behavior, or extra metadata without failing these tests.

**Recommended fix**

Assert full equality of every captured add dictionary against a separately declared expected literal containing exactly class, service, account, data-protection selection, accessibility, and value data. Add production-equivalent translation tests for each abstract key/value to its `Security` constant, and make the no-update/no-delete guarantee explicit in the transcript evidence (by interface inventory or counters at the live-operation boundary). Preserve the existing hit, miss, duplicate, malformed, inaccessible, random-failure, and add-failure count assertions.

### 5. High — Required validation and requirement-to-evidence artifacts are absent from the stable snapshot

**Evidence**

- `openspec/changes/sdk-public-connect/tasks.md:8-35` leaves every implementation, test, packaging, documentation, evidence, post-implementation review, and archive task unchecked.
- `openspec/changes/sdk-public-connect/tasks.md:30-35` specifically requires packaging parity, production secure-channel integration, the full validation matrix, exact evidence capture, independent review remediation, and a final spec-to-evidence audit.
- The active change contains no `openspec/changes/sdk-public-connect/evidence` directory in the reviewed worktree.
- The present tests cover two supported-connect success/lifetime cases in `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:221-321`, but there is no saved production TLS integration result, CocoaPods/SwiftPM Security-link result, peak-retention measurement, one-wait/fail-closed audit, API inventory, or requirement-to-evidence mapping.

**Impact**

The worktree cannot yet support claims that the public connection path is packaging-equivalent, production-TLS-integrated, bounded at peak retention, race-complete, or spec-complete. This is release-blocking under the repository workflow even after the source findings above are repaired.

**Recommended fix**

After remediation, execute every command required by tasks 4.1 through 4.5 without weakening gates. Save exact commands, run identity, exit status, output, counts, inventories, and audits under the active change's `evidence` directory; map every requirement and scenario to concrete evidence. Mark each checkbox only after its stated evidence exists, then run a fresh three-dimension review round and final strict OpenSpec/spec-to-evidence audit.

### 6. Low — The process-lease document contradicts the newly supported public API

**Evidence**

- `Documentation/SDK-Connection-Lease.md:3` correctly states that explicit `connect(code:)` claims the lease.
- `Documentation/SDK-Connection-Lease.md:5` immediately states that the lease “adds no public `connect` or `disconnect` method in this change.”
- `Documentation/SDK-Public-API.md:9` and `README.md:7-15` state that `connect(code:)` is now supported.
- `openspec/changes/sdk-public-connect/tasks.md:32` requires an English documentation and terminology audit.

**Impact**

SDK consumers and maintainers receive mutually exclusive lifecycle guidance from adjacent paragraphs, weakening the otherwise accurate security and ownership documentation.

**Recommended fix**

Rewrite line 5 to say that the lease itself remains internal and exposes no lease handle or disconnect API, while public `connect(code:)` composes it. Run the planned documentation terminology audit for any remaining “future connect” language before recording documentation evidence.

## Positive Security and Packaging Observations

- `Documentation/Transport-Security.md:17-38` accurately distinguishes mandatory TLS encryption from pre-established Viewer authentication and explains connection-local anchoring, active-attacker limits, pairing-code publicity, and installation-ID correlation.
- `SDK/Sources/NearWire/Connection/SDKPublicConnectionErrors.swift:7-104` maps internal outcomes to fixed content-free public codes/messages without forwarding Security status, network descriptions, endpoints, certificates, metadata, Events, or pairing values.
- `SDK/Sources/NearWire/Connection/SDKInstallationIdentity.swift:33-102` uses modern Security APIs, authentication-UI skip, data-protection Keychain selection, `WhenUnlockedThisDeviceOnly`, and `SecRandomCopyBytes`; no production update/delete/logging path was found.
- `Package.swift:49-60` and `NearWire.podspec:41-45` link only Apple's `Security.framework` on the SDK target/subspec, and the distribution validation scripts encode the same expectation.

