# Post-Implementation Security, Performance, and Documentation Review — Round 4

Reviewed the complete current active-pump diff from scratch, including the proposal, design, capability specifications, tasks, production and test source, user documentation, validation scripts, all evidence artifacts, and prior implementation reviews. Prior findings were treated only as verification targets. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Findings

### 1. MEDIUM — The task/timer/power inventory still omits the suspended owner-binding registration Task

**Evidence**

- Runner claim creates the immutable `SDKActiveLiveOperations` value, installs the binding token, starts the policy deadline, and launches an unstructured Task that strongly captures `dependencies`, `liveOperations`, the wake token, and signal ingress while awaiting wake registration (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:521-566`).
- The specification explicitly permits this additional resource: owner binding may suspend one bounded actor operation and must not create an unbounded task family (`specs/sdk-active-event-pump/spec.md:303`). It is separate from the negotiation-only owner-refresh Task, which starts only after binding reaches policy negotiation.
- Terminal cleanup invalidates `activeBindingToken`, clears the core's active dependency/live-operation references, and closes the shared gate, but it has no retained Task handle to cancel (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1839-1889`). The registration Task can therefore continue to retain its captured owner/channel/gate/live-operation closures until the actor call returns; its late result is safely rejected and an installed wake is removed through the captured live-operation value (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:569-579`).
- The ownership evidence presents its list as the complete active task inventory but includes only policy deadline, owner refresh, outbound drain/decision, incoming publication/decision, and signal routing (`evidence/ownership-resource-audit.md:38-50`). It then states that all tasks are cancelled and released at terminal cleanup, which is not true of the unretained binding Task.
- The user-facing power section repeats the same list and likewise omits the one suspended binding operation (`Documentation/SDK-Active-Event-Pump.md:54-68`). Task 7.5 is checked as an exact task/timer/power audit (`tasks.md:42-43`).

**Impact**

The omitted operation is singular, token-protected, gate-bound, and eventually self-releasing; this review found no unbounded Task family, polling loop, post-terminal mutation, or permanent retention defect. However, the published resource inventory understates peak binding work and overstates immediate terminal release. That makes the evidence inaccurate at the exact live-operation boundary introduced to prove owner/channel/gate identity.

**Required remediation**

Add one owner-binding wake-registration Task/operation to both the user-facing power section and the ownership/resource audit. State that it is started once, carries the binding result token, captures the immutable live-operation value, may outlive terminal cleanup until the bounded actor call returns, cannot commit after gate close, removes an already-installed matching wake on stale delivery, and then releases its captures. Distinguish token invalidation and eventual self-release from Tasks that the core directly retains and cancels. Reconfirm Task 7.5 only after the corrected inventory is recorded.

## Verified Controls Without Findings

- The publication-first test now publishes through the real gate, holds core completion, terminates the session, and proves the stale result cannot change terminal accounting, buckets, policy state, output cardinality, or channel cancellation. The separate terminal-first test proves no publication when terminal wins.
- The focused evidence now records 165 passing `NearWireTests`, including 70 active-session and 26 buffer tests. The current strict-concurrency package records 359 passing tests; repository packaging, iOS Simulator, Core parity, production TLS, and CocoaPods gates were rerun after the final production and test edits.
- `SDKActiveLiveOperations` is constructed only from the exact validated owner, admitted secure channel, and shared gate. Test hooks run before the typed operations but cannot replace route, codec, clock result, mailbox, owner actor, channel, or gate behavior.
- Incoming FIFO/in-flight bytes and counts, deadline heap cardinality, callback ingress, frame work, policy transactions, secure sends, queue work, blocked candidates, and subscriber buffers remain independently bounded. Idle and blocked operation is event-driven without recurring polling.
- Active traffic remains on the admitted TLS 1.3 channel. Diagnostics remain closed and code-derived; no pairing data, endpoint, route, Event content, wire bytes, certificate data, peer text, or underlying error is added to descriptions or reflection.
- The diff adds no supported SDK API, product, target, dependency, CocoaPods subspec, entitlement, privacy declaration, persistence, Keychain access, lifecycle observation, reconnection, UI, process lease, or performance collection.

## Validation Performed During Review

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round4-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round4-swiftpm-cache swift test --filter SDKSessionAdmissionTests`: PASS — 70 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `./scripts/verify-boundaries.sh`: PASS — module imports, Core SPI, secure-transport construction, SwiftPM/CocoaPods paths, distribution manifest, and dependency isolation.
- `git diff --check`: PASS before this report was added.

## Unresolved Count

**1 unresolved finding: 1 Medium.** Security/performance/documentation closure is not granted.
