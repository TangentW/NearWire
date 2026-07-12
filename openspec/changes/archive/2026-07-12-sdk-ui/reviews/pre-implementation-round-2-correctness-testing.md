# Pre-Implementation Correctness and Testing Review — Round 2

## Scope

Re-reviewed the complete remediated `sdk-ui` proposal, design, delta specifications, tasks, and current SDK lifecycle/status implementation against all six Round 1 correctness/testing findings. The review additionally exercised the planned fail-closed disconnect and rapid panel disappearance/recreation semantics. This is report-only; no production, test, proposal, design, specification, or task source was modified.

## Round 1 Finding Disposition

1. **Public-status action derivation: resolved.** The total conservative matrix no longer guesses retained intent. Disconnected error presentation offers Connect plus an optional Disconnect/reset, while host-owned pre-discovery is normalized after one supported preflight error (`design.md:64-66`; `specs/sdk-ui/spec.md:66-78`).
2. **Cooperative-cancellation Task bound: not fully resolved.** The shared Disconnect coordinator closes duplicate disconnect waiters, but the cancelled-Connect predecessor bound is not preserved across another activation or rapid panel recreation. See Finding 2 below.
3. **Action and observation teardown authority: resolved.** Disappearance synchronously advances both generations, cancels both handles, and requires every post-`await` mutation to match its exact generation; identity replacement carries the same invalidation requirement (`design.md:54-56`; `specs/sdk-ui/spec.md:110-123`). Held status/action, repeated start/stop, and rapid replacement tests are expressly planned (`design.md:88-95`; `tasks.md:15-18`).
4. **Action/status error winner order: resolved.** Status observation never clears an action error, and the four clearing boundaries are closed and deterministic in either scheduling order (`design.md:68-72`; `specs/sdk-ui/spec.md:80-99`).
5. **Deterministic status/error fixtures: resolved in the implementation plan.** The plan adds `NearWire` as a direct `NearWireUITests` dependency and limits `@testable import NearWire` to internal fixtures, without widening public initializers (`design.md:88-90`; `tasks.md:19`).
6. **Unicode scalar-prefix coverage: resolved in the implementation plan.** The matrix now includes 63/64/65 ASCII bytes, exact and short 2-/3-/4-byte scalars, decomposed combining scalars, joined emoji, exact forwarding, and discarded suffix assertions (`design.md:90-91`; `tasks.md:14`).

## Actionable Findings

### 1. P1 / High — The specified Disconnect-preempts-Connect scenario has no defined visible action

**Confidence: 10/10**

The total action matrix says a panel-owned pending Connect exposes Cancel (`design.md:47-50,60`; `specs/sdk-ui/spec.md:66-68`). Cancel only advances generation and cancels the Connect Task; explicit Disconnect separately cancels Connect and enters the shared disconnect coordinator (`design.md:60-64`). Nevertheless, the normative scenario requires the user to activate Disconnect while that same UI-started Connect is pending, and requires shared cleanup to begin immediately (`specs/sdk-ui/spec.md:56-59`). Under the stated total/precedence rule, progress status does not make Disconnect reachable because the more specific panel-owned action is Cancel. The documents therefore specify two different outcomes for the same state without saying whether Cancel and Disconnect are both visible, whether Cancel is implemented as Disconnect, or which action has precedence.

This matters beyond wording: cancellation alone awaits the SDK's cooperative connect cleanup through the cancelled caller, whereas explicit `disconnect()` establishes the shared lifecycle cleanup route and the coordinator state used by a recreated panel. A test cannot assert the required preemption outcome until the user action is defined.

**Required remediation:** choose one closed behavior and use it consistently in proposal, design, requirement, scenarios, and action-table tests. Either expose both Cancel and Disconnect while a panel-owned Connect is pending and define their distinct effects, make the sole Cancel action enter the shared Disconnect coordinator, or remove the Disconnect-preemption scenario and prove cancellation-only cleanup/recreation semantics instead. Include exact action-set assertions before discovery, during every progress state, and during held cancellation.

### 2. P1 / High — Re-activation can exceed the claimed one cancelled-Connect-predecessor hard bound

**Confidence: 10/10**

Cancel or disappearance advances generation and cancels the current Connect without claiming termination, permitting one noncooperative predecessor to remain (`design.md:54-60`; `specs/sdk-ui/spec.md:47`). Nothing then records process/controller-wide pending cancellation, disables a new Connect until that predecessor returns, or deduplicates Connect across a recreated panel. The coordinator covers only Disconnect (`design.md:62-64`; `specs/sdk-ui/spec.md:49`). Consequently this legal sequence exceeds the normative maximum:

1. Connect A remains held and ignores cancellation temporarily.
2. Cancel or disappearance cancels A, making it predecessor A.
3. The same or a rapidly recreated panel starts Connect B because no shared disconnect is active and public status may still be idle/disconnected.
4. Cancel or disappearance cancels B before it reaches or returns from SDK preflight, making it predecessor B while A is still live.

The SDK will eventually reject or cancel B conservatively, but actor scheduling and Task cancellation are not synchronous completion. For at least one scheduling interval two cancelled UI-created Tasks can coexist, and an unconstrained internal fake controller can hold both indefinitely. Exact action generations make both tails inert; they do not enforce the stated live-Task and retained-input bound. The planned rapid-recreation/live-operation test says it will prove the bound (`design.md:92-93`; `tasks.md:18,23`) but no mechanism in the design can satisfy that adversarial barrier sequence.

Fail-closed Disconnect itself is otherwise bounded: one code-free coordinator entry per controller is reused across panels, and the sole process lease bounds an indefinitely held cleanup route (`design.md:62-64,82`; `specs/sdk-ui/spec.md:49,61-64`). The gap is specifically the independent Connect predecessor lifetime before or without shared Disconnect ownership.

**Required remediation:** add controller-identity-wide Connect cancellation ownership, or block all new Connect activation until the prior Task positively completes. If Cancel is changed to request shared Disconnect, keep Connect disabled as Disconnecting until a later disconnected/shutdown status and coordinator reconciliation. Specify how a recreated model synchronously learns this gate without starting construction work. Add a deterministic barrier test for `Connect A -> Cancel/disappear -> recreate -> Connect B -> Cancel/disappear` before A returns; assert at every step no more than one cancelled predecessor, no more than one bounded input copy outside the current model, exact controller invocation counts, and eventual gate removal after completion.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check -- openspec/changes/sdk-ui`: PASS.

## Verdict

**Unresolved actionable finding count: 2 — 2 High. Pre-implementation correctness/testing approval is not granted.**

The conservative public-state matrix, teardown generations, error winner rule, fixture dependency, UTF-8 coverage, and fail-closed Disconnect deduplication are now adequately specified. The action surface and cancelled-Connect ownership must be made mutually consistent and must enforce the claimed rapid-recreation hard bound before implementation begins.
