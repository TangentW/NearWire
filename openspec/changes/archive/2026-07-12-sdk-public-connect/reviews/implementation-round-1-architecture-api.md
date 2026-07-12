# Post-Implementation Architecture and API Review — Round 1

## Scope Reviewed

I reviewed the complete current worktree implementation for `sdk-public-connect` against its proposal, design, capability specifications, task plan, `NearWire-Platform-Architecture.md`, package manifests, public consumer fixture, SDK/Core placement, and focused connection tests. This was a report-only review; no production, test, specification, or documentation source was modified.

The broad composition is sound: the public API remains one instance-actor `connect(code:)` operation; platform-neutral wire sizing remains in `Core`; iOS Keychain, discovery/admission composition, process ownership, and active-owner binding remain in `SDK`; the permanent core no longer stores a strong `NearWire`; and SwiftPM/CocoaPods both link only Apple's `Security.framework` for the SDK target.

## Findings

### 1. P1 / High — A cancellation latched after lease claim can still start the installation-identity worker

**Evidence**

- `connect(code:)` checks `Task.isCancelled` only during preflight (`SDK/Sources/NearWire/NearWire.swift:150-151`). After reserving the actor slot and claiming the process lease, it invokes the synchronous `afterLeaseClaim` hook and then unconditionally starts `loadInstallationIdentity()` (`NearWire.swift:179-202`).
- The outer cancellation handler can concurrently latch `.task` in the shared gate (`NearWire.swift:137-143`), but there is no gate/token/Task authorization check between lease claim and identity-worker start and no identity-stage transition target.
- Authorization is checked only after the identity operation and both identity-completion hooks return (`NearWire.swift:202-229`). Therefore a deterministic race can pause in `afterLeaseClaim`, cancel the Task, resume the hook, and still perform Keychain IPC.
- The design requires cancellation-before-target to reject installation and every suspension to recheck gate and actor token (`openspec/changes/sdk-public-connect/design.md:65-69`). The normative requirement repeats that rule (`specs/sdk-public-connect/spec.md:86-90`), and task 3.10 explicitly requires cancellation/shutdown coverage during identity (`tasks.md:26`).

**Requirement impact**

The implementation starts lower-stage work after the attempt has synchronously lost authority. It also performs avoidable Keychain IPC and holds the process lease until that non-cancellable work finishes, rather than taking the no-worker cleanup path when cancellation won before worker installation.

**Recommended fix**

Add one synchronous current-token, shared-gate, and `Task.isCancelled` authorization check immediately before starting the identity operation. Model identity as an explicit gate stage/target if the target-generation protocol is intended to cover all named stages; because Security IPC is non-cancellable, the target can reject pre-start installation while cancellation after start follows the existing retain-lease-until-completion rule. Add a barrier test where Task cancellation and shutdown each win at `afterLeaseClaim`, asserting zero identity calls, exact release, no discovery/state publication, and the specified public error.

### 2. P2 / Medium — One public lease release performs the underlying runtime release twice

**Evidence**

- The live wrapper captures a `ProcessConnectionLeaseHandle` in its release closure (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:36-46`). `SDKPublicConnectionLease.release()` clears the stored closure and invokes the retained closure once (`SDKPublicConnectionOrchestration.swift:48-55`).
- The closure calls `handle.release()`. When that consumed closure is then destroyed, its captured handle deinitializes, and `ProcessConnectionLeaseHandle.deinit` calls `release()` again (`SDK/Sources/NearWire/Session/ProcessConnectionLease.swift:96-121`).
- Each underlying call enters and exits the Objective-C synchronization runtime (`ProcessConnectionLease.swift:219-246`). Exact-token comparison prevents the second call from clearing a successor, but it does not make the runtime operation occur exactly once.
- The design requires exact release once and specifically calls for release enter/exit validation (`openspec/changes/sdk-public-connect/design.md:147-159`). The capability requires terminal to release the exact lease once (`specs/sdk-public-connect/spec.md:106-114`), and tasks 3.9 and 3.10 require injected runtime evidence for repeated/stale release and every cleanup branch (`tasks.md:25-26`). Current orchestration tests inject a closure directly, so they bypass the live handle wrapper and cannot expose this double runtime call (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:228-231,332-335,379-382,481-484`).

**Requirement impact**

The public wrapper is idempotent only at its outer layer, while the production runtime boundary observes two release operations. This violates the exact-release ownership contract and creates an unnecessary second synchronization enter/exit whose failure cannot be represented by the already-cleared wrapper state.

**Recommended fix**

Give `ProcessConnectionLeaseHandle` an internal one-shot release gate and make `deinit` use that same gate, or transfer the handle into a wrapper that invokes only one terminal release path without a second deinit release. Add a production-shaped injected-runtime test that constructs `SDKPublicConnectionLease(handle:)` and asserts one enter, one exact-token clear, and one exit for explicit release, repeated release, and deinitialization.

### 3. P2 / Medium — The transition gate can deliver duplicate cancellation requests to the same target

**Evidence**

- `SDKSessionTransitionGate.requestCancellation` records only the first Task reason, but it fetches and invokes the current target on every accepted call, including repeated `.task` calls (`SDK/Sources/NearWire/Connection/SDKSessionTransitionGate.swift:87-101`).
- During admission, the outer public cancellation handler calls that method (`SDK/Sources/NearWire/NearWire.swift:137-143`), while `SDKSessionAdmission.run()` installs a nested cancellation handler that calls the same gate again and separately schedules `self.cancel()` (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:77-83`). A single Task cancellation can therefore request cancellation from the admission owner multiple times.
- When target installation observes an already-cancelled gate, `installTarget` invokes the supplied cancellation closure immediately (`SDKSessionTransitionGate.swift:104-120`), and each caller then explicitly cancels the same owner again on the failed guard: admission (`NearWire.swift:293-303`), attachment (`NearWire.swift:425-435`), and active handle (`NearWire.swift:485-494`).
- The normative contract says target-before-cancellation receives one request and every ordering uses one cancellation request per owner (`openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:86-95,106-114`). Existing tests assert the lower secure driver eventually cancels once (`SDKPublicConnectionOrchestrationTests.swift:201-216`), but that actor/relay idempotence masks duplicate target delivery and does not count the gate target closure itself.

**Requirement impact**

The shared gate is not the single exact cancellation authority promised by the design. Current owners happen to be defensive, but lifecycle correctness depends on downstream idempotence and extra unstructured Tasks instead of the gate's one-owner/one-request invariant.

**Recommended fix**

Make the gate consume or mark the installed target as cancellation-delivered under the lock before invoking its closure, so repeated requests cannot redeliver to the same generation. Define `installTarget`'s failed result as either “the gate already delivered cancellation” or “the caller must cancel,” not both, and remove the duplicate caller-side action accordingly. Avoid the admission handler's separate `self.cancel()` when gate delivery owns that request. Add deterministic counters for admission, attachment, and active-handle target closures covering cancellation-before-installation, target-before-cancellation, nested handler delivery, replacement, and repeated shutdown/Task requests.

## Review Result

**Unresolved actionable findings: 3** — one High and two Medium. A fresh architecture/API review is required after remediation.

`git diff --check` passed. A focused `swift test --filter SDKPublicConnection` attempt could not run in the restricted review sandbox because SwiftPM's manifest compiler could not create/use its module cache; this report therefore relies on source, specification, and existing-test inspection rather than claiming a new passing test run.
