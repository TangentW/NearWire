# Pre-Implementation Correctness and Testing Review — Round 4

## Scope

Re-reviewed all `sdk-ui` pre-implementation artifacts after the coordinator phase-broadcast redesign. The review traced simultaneous panels, phase subscription registration and termination, exact idle-entry removal, weak origin-only action results, both asymmetric Connect/Disconnect acknowledgement orders, rapid disappearance/recreation, Cancel-as-Disconnect, active-session disappearance, and all earlier action-matrix, error-winner, fixture, and Unicode scalar-prefix requirements. This is report-only; no production, test, proposal, design, specification, or task source was modified.

## Verified Behavior

- **Simultaneous panels have a bounded coherent source.** Every live model owns an independent `AsyncStream` subscription with `bufferingNewest(1)`, while action admission remains serialized by the one controller-keyed coordinator (`design.md:60-70,88`; `specs/sdk-ui/spec.md:47-49,73-76`).
- **Termination and removal are identity-safe.** Subscription termination removes only its exact continuation; idle entries remain until the exact subscriber count reaches zero, preventing an `ObjectIdentifier` ABA window. The tasks require exact subscriber removal, no terminated-subscriber accumulation, and final cleanup (`design.md:62,70`; `specs/sdk-ui/spec.md:49`; `tasks.md:18,23`).
- **Action results have one safe owner.** The Connect token carries at most one weak origin-completion closure. Results are neither broadcast nor allowed to mutate a model unless its subscription and action generation remain current (`design.md:62,88`; `specs/sdk-ui/spec.md:49`).
- **Both preemption completion orders are normative and testable.** The coordinator remains Disconnecting until both exact acknowledgements arrive, and the task plan now requires independent Connect-first and Disconnect-first barriers (`specs/sdk-ui/spec.md:51,78-81`; `tasks.md:18`).
- **Rapid recreation remains gated.** Disappearance converts the exact held Connect to shared Cancelling without starting Disconnect; a replacement subscription observes the shared phase and coordinator admission prevents Connect B before A acknowledges (`design.md:66`; `specs/sdk-ui/spec.md:51,68-71`).
- **Cancel-as-Disconnect remains one unambiguous path.** The Cancel-labeled action cancels the exact Connect, begins or joins the one shared Disconnect, and cannot admit another operation until both tails finish (`design.md:64,72`; `specs/sdk-ui/spec.md:51,58-61,83-85`).
- **Ordinary disappearance does not disconnect an active route.** It cancels only an exact still-owned pending Connect and starts no Disconnect Task; established session ownership remains with the host (`design.md:56,66`; `specs/sdk-ui/spec.md:17-29,51`).
- **Earlier findings remain closed.** The conservative public-state matrix, deterministic status/action error winner rule, direct `NearWire` test dependency, internal fixture access, and exhaustive UTF-8 scalar-prefix cases remain specified and assigned evidence (`design.md:72,78,94-103`; `tasks.md:15-19`).

## Actionable Finding

### 1. P2 / Medium — `AsyncStream` initial yield does not guarantee the phase is applied before first action rendering

**Confidence: 9/10**

The design and requirement say a newly presented panel receives the coordinator's latest phase before exposing actions (`design.md:70`; `specs/sdk-ui/spec.md:49`). The only specified handoff is registration immediately yielding the phase into an `AsyncStream` with `bufferingNewest(1)`. `yield` makes the value available to the iterator, but the model's structured consumer still processes it after an asynchronous `next()`/executor turn. Unless an additional synchronous snapshot handoff exists, a new or recreated model can render its default idle/public-status action set before consuming Cancelling or Disconnecting. The coordinator still rejects Connect B, so the operation hard bound is safe, but the panel temporarily violates the total action-presentation rule and the stated “before exposing actions” guarantee.

This is especially observable in the required recreation sequence: A is held in Cancelling, panel B appears, registration buffers Cancelling, but B can initially display Connect until its phase-observation Task runs. The current tests request “immediate latest status/phase” (`tasks.md:17`) without requiring an assertion before the first suspension/executor yield, so an eventually correct consumer would pass.

**Required remediation:** make subscription registration atomically return both the synchronous current phase and the bounded stream/registration identity, or provide another main-actor synchronous snapshot used to initialize the model before its observation Task is launched. Keep this work presentation-triggered so view construction remains side-effect-free. Add a deterministic test that holds the coordinator in connecting, cancelling, and disconnecting; presents a new model; asserts its exact disabled/Cancel action synchronously before any executor yield; verifies an immediate activation cannot present or start Connect B; and then proves later streamed phases and exact termination still behave normally.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check -- openspec/changes/sdk-ui`: PASS.

## Verdict

**Unresolved actionable finding count: 1 — 1 Medium. Pre-implementation correctness/testing approval is not granted.**

The multi-panel phase stream, weak origin result, dual-acknowledgement barriers, cancellation gate, resource bounds, and previous correctness remediations are otherwise sound. The remaining gap is the synchronous initial-phase handoff needed to make the first rendered action match the already-active coordinator gate.
