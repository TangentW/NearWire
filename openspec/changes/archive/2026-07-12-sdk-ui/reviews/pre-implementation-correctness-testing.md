# Pre-Implementation Correctness and Testing Review

## Scope

Reviewed the complete `sdk-ui` proposal, design, delta specifications, tasks, and pre-implementation evidence against the current `NearWire` lifecycle/status API, latest-value stream hub, public model construction boundaries, NearWireUI shell, package graph, and existing UI tests. This is report-only; no production, test, proposal, design, specification, or task source was modified.

## Actionable Findings

### 1. P1 / High — The panel cannot derive the required action from public status in every supported lifecycle mode

**Confidence: 10/10**

The design presents Connect for idle/disconnected and Disconnect for initial/recovery/active/suspended work (`design.md:45-50`), while the normative action requirement makes Disconnect available for initial, recovery, active, and suspended work (`specs/sdk-ui/spec.md:45-57`). Public `NearWireConnectionStatus` exposes only state, last error, retry number, and suspension (`SDK/Sources/NearWire/NearWirePublicModels.swift:209-235`). It does not expose lifecycle intent or an operation owner.

That omission is observable in two supported cases. A disabled transient terminal ends as disconnected with an error and retained intent, while permanent failure/exhaustion ends as disconnected with an error and no intent (`openspec/specs/sdk-connection-lifecycle/spec.md:126-133`). The first requires disconnect before a new code can connect; the second does not. A host-started initial connect also remains at its prior stable state during pre-discovery work, so an injected panel does not know that initial work exists unless it started the action itself. The panel cannot satisfy the stated button rule for host-owned operations without either presenting a Connect action that predictably returns `connectionIntentExists`/`connectionInProgress` or duplicating private lifecycle classification.

**Required remediation:** choose a rule expressible through supported API. One narrow option is: use the UI-owned action to expose Disconnect during UI-started pre-discovery work; use status for discovering/connecting/connected/reconnecting/suspended; treat disconnected-with-error as a normalization state that offers Disconnect until the SDK clears the error, then Connect; and explicitly document that an externally started pre-discovery attempt can only be resolved by SDK preflight. Otherwise extend the supported status API with explicit connection ownership/intent, which would broaden this change. Add table tests for UI-owned and host-owned initial work, disabled transient retained intent, permanent terminal, exhaustion, suspension without intent, and shutdown.

### 2. P1 / High — One live action Task is incompatible with disconnect preemption as specified

**Confidence: 9/10**

The design and resource boundary allow only one action Task (`design.md:54-60,74-80`), but Disconnect must cancel an incomplete Connect Task and concurrently execute and await `nearWire.disconnect()` (`specs/sdk-ui/spec.md:45-57`). Swift Task cancellation is cooperative. Replacing the stored Connect handle with a Disconnect Task does not end the cancelled Task; a fake or SDK operation may remain suspended during non-cancellable cleanup. The UI then has two live UI-created Tasks even if it retains only one handle. Waiting for Connect completion before creating Disconnect avoids overlap but no longer gives Disconnect independent preemptive execution and requires another asynchronous caller to perform the wait.

**Required remediation:** define the actual bounded ownership model. Either permit at most two live Tasks only during preemption (one cancelled connect plus one authoritative disconnect), ensure the old Task captures no model/input and gate both completions by generation, or design one command-executor Task that can receive preemption without spawning a child and specify when disconnect begins. Add a noncooperative fake-connect barrier that remains held after cancellation, activate Disconnect, and prove exact task/retention bounds, one disconnect invocation, no stale mutation, and no model cycle.

### 3. P1 / High — Teardown cancellation lacks explicit action and observation invalidation

**Confidence: 9/10**

Disappearance must cancel observation/action and clear input/error (`design.md:54-60`; `specs/sdk-ui/spec.md:17-29,82-85`), but only Disconnect is explicitly required to advance action generation. No observation generation or presentation token is defined. Cancellation alone cannot prove teardown: a noncooperative Connect may later return an error using the still-current generation, and an old status observation may already hold a value when disappearance clears the model. On re-presentation with the same `@StateObject`, the old observation can overwrite the new stream's immediate latest snapshot or repopulate cleared error state.

**Required remediation:** teardown must synchronously invalidate both action and observation authority before cancelling handles and clearing state. Each update after an `await` must verify the exact current generation/presentation token. Starting observation must be idempotent, replace no current observer, and support a fresh token after reappearance; model deinit must perform the same cancellation without MainActor-unsafe work. Add held fake-connect and held status-iterator tests for disappearance-before-completion, completion-before-disappearance, old yield after teardown, disappearance/reappearance with a newer initial snapshot, repeated start/stop, subscriber count at most one, and zero retained work after release.

### 4. P2 / Medium — Status-versus-action error winner order has no deterministic oracle

**Confidence: 8/10**

The design gives current action error display priority, then says a healthy progress or connected status clears a stale action error when no newer action owns it (`design.md:62-66`). The latest-value status stream carries no action generation or causal identifier (`SDK/Sources/NearWire/AsyncStreamHubs.swift:192-245`). Therefore a buffered healthy status from before an action failure, a host-owned status update, and a status caused by the current action are indistinguishable when they reach the MainActor. “No newer action owns it” does not define whether the status may clear the current action's error, which event wins if status and completion are ready together, or what Disconnect and teardown do to both error sources. Task 3.2 names stale completion but not these status/action winner pairs (`tasks.md:12-16`).

**Required remediation:** define a total rule. The simplest is to clear action error only on new action start, generation-current success, Disconnect start/completion, or teardown, never from status observation. If status-driven clearing is retained, add a monotonically increasing observation revision and record the minimum revision allowed to clear each action error. Require barriers for healthy/error status before and after connect success/failure, simultaneous readiness in both actor orders, host-owned status changes, Disconnect preemption, and teardown. Assert both the stored sources and the displayed action-first selection.

### 5. P2 / Medium — The planned UI test target cannot construct the status and safe-error fixtures it requires

**Confidence: 10/10**

Task 3.1 requires pure presentation coverage for every state, retry, suspension, and safe error (`tasks.md:12-15`). `NearWireConnectionStatus` and `NearWireError` expose read-only fields but only internal initializers (`SDK/Sources/NearWire/NearWirePublicModels.swift:219-236`; `SDK/Sources/NearWire/NearWireError.swift:39-47`). `NearWireUITests` currently depends only on the `NearWireUI` target (`Package.swift:111-115`), so `@testable import NearWireUI` does not grant access to NearWire module internals. It can obtain a real idle snapshot, but cannot deterministically construct the full status/error matrix described by the plan.

**Required remediation:** specify a test-only seam before implementation. Prefer adding `NearWire` as a direct test-target dependency and using `@testable import NearWire` only in NearWireUITests, or test an internal UI presentation function from primitive fields plus a smaller real-status integration test. Do not make SDK status/error initializers public merely for tests. The evidence matrix must distinguish pure mapping coverage from public-view smoke coverage.

### 6. P2 / Medium — UTF-8 tests do not yet prove the required scalar-boundary behavior

**Confidence: 9/10**

The requirement retains the longest prefix ending at a Unicode scalar boundary within 64 UTF-8 bytes (`specs/sdk-ui/spec.md:31-43`). Task 3.1 calls for ASCII and multibyte scalar boundaries (`tasks.md:14`) but does not require a case where Swift `Character` boundaries differ from Unicode scalar boundaries. An implementation based on `String.prefix` or `Character` iteration can pass ordinary ASCII/emoji tests while truncating earlier than the required last scalar for decomposed graphemes or joined emoji sequences.

**Required remediation:** require fixtures at 63/64/65 ASCII bytes, exact-fit and one-byte-short two-/three-/four-byte scalars, a decomposed base-plus-combining-mark sequence crossing byte 64, and a multi-scalar joined emoji crossing the limit. Assert the retained UTF-8 byte count, valid String construction, exact scalar-prefix value, exact forwarded value, and absence of any suffix in model state after paste.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check -- openspec/changes/sdk-ui`: PASS.

## Verdict

**Unresolved actionable finding count: 6 — 3 High, 3 Medium. Pre-implementation correctness/testing approval is not granted.**

The injected-instance scope and native UI boundary are sound, but action derivation, asynchronous ownership, teardown authority, error precedence, and deterministic fixture strategy must be closed before implementation can provide the stated guarantees.
