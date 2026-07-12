# Pre-Implementation Correctness and Testing Review — Round 5

## Scope

Performed the final pre-implementation correctness/testing review of the complete `sdk-ui` artifacts after adoption of the atomic `(initialPhase, stream, registrationToken)` coordinator handoff. Re-traced first presentation, rapid disappearance/recreation, simultaneous panels, exact subscriber termination and entry removal, weak origin-only completion, Cancel-as-Disconnect, asymmetric Connect/Disconnect completion, fail-closed cleanup, active-session disappearance, conservative action mapping, error precedence, internal fixtures, and Unicode scalar-prefix tests. This is report-only; no production, test, proposal, design, specification, or task source was modified.

## Verification Results

### Atomic first-phase handoff closes the first-render gap

Coordinator registration is one synchronous main-actor operation that atomically installs the exact continuation and returns its current phase, later-value stream, and registration token. The model must apply the returned phase before exposing an action or awaiting the stream, while later changes use `bufferingNewest(1)` (`design.md:60-62,70`; `specs/sdk-ui/spec.md:45-49`). A panel appearing during Connecting, Cancelling, or Disconnecting therefore cannot render stale Connect from an asynchronous initial-yield delay. The normative scenario expressly requires this before the first action presentation and without an executor turn (`specs/sdk-ui/spec.md:78-81`).

The implementation tasks require a deterministic synchronous-initial-phase test before first action presentation, in addition to construction-side-effect freedom (`tasks.md:15-18`). This is an adequate oracle: an implementation that merely buffers an initial stream element and becomes correct after a yield will fail.

### Earlier concurrency and ownership findings remain closed

- Connect is accepted only from coordinator idle. A disappeared panel leaves Connect A in shared Cancelling, and a recreated panel atomically receives that gate before it can expose or start Connect B (`design.md:62,66,70`; `specs/sdk-ui/spec.md:49,68-81`).
- Connecting exposes one unambiguous Cancel-labeled action whose effect is the shared Disconnect preemption path. Repeated panels/actions join the same exact entry (`design.md:64,72`; `specs/sdk-ui/spec.md:51,58-61,88-90`).
- The coordinator owns at most one exact Connect Task plus one preempting code-free Disconnect Task. It remains Disconnecting until both exact acknowledgements arrive, and independent Connect-first and Disconnect-first barrier tests are required (`specs/sdk-ui/spec.md:47,51,83-86`; `tasks.md:18`).
- Every simultaneous panel has its own bounded later-phase subscription. Exact termination removes only its continuation, and an idle entry is removed only at zero subscribers, preserving coherence and `ObjectIdentifier` reuse safety (`design.md:62,70,88`; `specs/sdk-ui/spec.md:49,73-76`; `tasks.md:17-18,23`).
- A Connect result belongs only to its exact weak origin and is additionally gated by current subscription/action generation. It is neither broadcast nor allowed to retain a model (`design.md:62,88`; `specs/sdk-ui/spec.md:49`).
- Ordinary disappearance cancels only an exact still-owned pending Connect and starts no Disconnect, so an established active connection remains host-owned (`design.md:56,66`; `specs/sdk-ui/spec.md:17-29,51`).
- Fail-closed Disconnect remains one code-free shared Task for the sole process route, with no per-panel cleanup Task, waiter, or callback list (`design.md:68,86-90`; `specs/sdk-ui/spec.md:47-51`).

### Earlier mapping and testability findings remain closed

- The total public-state action matrix safely handles retained-intent ambiguity, host-owned pre-discovery, terminal error shapes, suspension, progress, and shutdown without inferring private lifecycle state (`design.md:72`; `specs/sdk-ui/spec.md:88-100`; `tasks.md:15,17`).
- Status observation never clears an action error; the explicit clearing boundaries and action-first display order give deterministic winner behavior (`design.md:78`; `specs/sdk-ui/spec.md:102-121`).
- `NearWireUITests` is planned to depend directly on `NearWire` and use `@testable import NearWire` only for internal status/error fixtures, without widening supported initializers (`design.md:94-96`; `tasks.md:19`).
- UTF-8 coverage includes 63/64/65 ASCII bytes, exact and short 2-/3-/4-byte scalars, decomposed combining scalars, and joined emoji, with exact retained/forwarded bytes and discarded-suffix assertions (`design.md:97`; `tasks.md:16`).

## Actionable Findings

**Zero.**

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check -- openspec/changes/sdk-ui`: PASS.

## Verdict

**Unresolved actionable finding count: 0. Pre-implementation correctness/testing approval is granted.**

The plan now provides deterministic, bounded, and testable behavior for initial rendering, concurrent panels, cancellation and cleanup races, result ownership, teardown, error precedence, and scalar-bounded input. Implementation must still produce the stated evidence before completion review, but no correctness/testing design blocker remains.
