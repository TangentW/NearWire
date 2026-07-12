# SDK UI Pre-Implementation Security, Performance, and Documentation Review — Round 2

## Result

**Unresolved actionable finding count: 1** — one High.

The remediation correctly stops equating cancellation with Task completion, uses weak model re-entry, discloses the bounded one-shot pairing-code copy, deduplicates Disconnect through a code-free process-local waiter, and replaces the unsupported live-region promise with closed accessibility values plus source and rendering evidence. One resource-bound gap remains: the cancelled Connect predecessor is not coordinated across model teardown and panel recreation.

## Finding

### 1. High — The one-Connect-predecessor bound is model-local and can be exceeded after panel recreation

**Evidence**

- A model owns and cancels its current Connect Task, and that cancelled Task may remain alive with the controller and one bounded input copy until the SDK acknowledges cancellation (`design.md:56-60`; `specs/sdk-ui/spec.md:45-49`).
- Disappearance invalidates and tears down the old model, while replacing the injected instance removes the old child. The surviving Connect Task deliberately cannot retain or mutate that model (`design.md:56,60`; `specs/sdk-ui/spec.md:17-29,110-123`).
- The only process-local coordinator described by the design is for Disconnect. A new model queries that coordinator only to discover an existing Disconnect request; no shared Connect-in-flight/predecessor entry tells it that an earlier model's cancelled Connect has not completed (`design.md:62-64`; `tasks.md:8-11`).
- Consequently, a new panel for the same controller can create another Connect Task while the prior panel's noncooperative cancelled Task is still suspended. Repeating present, Connect, and disappear can leave multiple cancelled caller Tasks, each retaining the controller and its own capped argument. SDK actor preflight and the process lease bound admitted connection work, but they do not synchronously prevent caller Tasks from accumulating before the actor acknowledges each call.
- The planned held-noncooperative Connect and rapid disappear/reappear evidence claims it will prove a single-predecessor hard bound (`design.md:92-93`; `tasks.md:17-23`), but the specified ownership mechanism cannot make that assertion pass without relying on a fake or timing assumption that hides the recreation path.

**Impact**

The Round 1 model-retention cycle is fixed, and each individual pairing copy remains capped and non-secret. However, the total number of cancelled Tasks, retained controller references, and pairing-code copies is still unbounded under repeated panel recreation while cancellation completion is held. This contradicts the singular predecessor and pairing-retention guarantees in the proposal, capability, resource boundary, and planned evidence.

**Required change**

Add an exact-controller Connect admission/predecessor entry that survives model teardown, or explicitly weaken every affected guarantee to a per-model bound. To preserve the stated hard bound, the preferred design is to extend process-local coordination so a new model cannot create a Connect Task while the same controller has a current or cancelled-but-incomplete Connect Task. The entry must:

- be installed synchronously before Task creation and removed only by an exact token after Task return;
- retain no model, view, status, error, callback list, or second pairing copy;
- expose a closed pending-predecessor presentation so a recreated panel cannot offer Connect prematurely;
- define whether the bound is per exact controller or process-wide, and use that same scope in proposal, design, capability, tasks, and evidence; and
- be tested with a held cancellation, model release, repeated reconstruction of the same exact controller, repeated submission attempts, live-Task/input-copy counters, and stale-token removal.

## Verified Remediation and Boundaries

- Disconnect preemption now truthfully permits one non-cancellable, code-free shared waiter, deduplicates it across taps and panels, removes its exact-controller entry after return, and permits one fail-closed entry for the sole process-owned route. No per-panel waiter or callback list is planned.
- Long-running Connect and status tails re-enter the model weakly; disappearance synchronously invalidates generations and clears model input/error before cancellation. No Task is allowed to restore stale presentation.
- Pairing input remains a scalar-boundary UTF-8 prefix of at most 64 bytes, is memory-only, is never logged, persisted, reflected, exposed, placed on the pasteboard, or echoed through errors, and is not claimed to be securely zeroized. The plan now explicitly discloses the one-shot argument lifetime of a cancelled predecessor.
- Unexpected errors use one fixed sentence, while `NearWireError.message` remains the only permitted SDK diagnostic. Pairing, endpoint, certificate, Viewer, framework, and application descriptions remain excluded.
- The accessibility contract is now closed and testable: exact fixed-English presentation values cover every state/action/error, source audit binds accessibility modifiers and combined semantics, meaning is not color-only, and large accessibility Dynamic Type receives `ImageRenderer` construction evidence. The plan explicitly makes no automatic live-region announcement guarantee.
- Construction remains side-effect free. The UI injects but never constructs `NearWire`; does not claim active-session shutdown on disappearance; and adds no persistence, Keychain, pasteboard API, camera, notification, lifecycle observer, reachability, background execution, analytics, asset, font, bundle, entitlement, privacy declaration, or runtime dependency.
- Public API remains limited to the two SwiftUI view structs and supported NearWire facade values, with equivalent SwiftPM/CocoaPods inventory and no public or SPI model/controller/action type.
- The current production and test source remains the internal bootstrap marker and smoke test; implementation has not begun.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check`: PASS after this report was added.

## Final Verdict

**Not ready for implementation.** Close the cross-model Connect-predecessor admission gap and rerun this review. The prior Disconnect retention, weak-capture, pairing disclosure, accessibility evidence, live-region, security, distribution, and documentation findings are otherwise resolved at plan level.
