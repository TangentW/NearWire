# Pre-Implementation Correctness and Testing Review — Round 3

## Scope

Re-reviewed the complete `sdk-ui` pre-implementation artifacts after the exact-controller coordinator redesign. The review traced rapid disappearance/recreation, Cancel-as-Disconnect, both preemption completion orders, observer replacement, active-session disappearance, fail-closed cleanup, and the six original status/error/fixture/UTF-8 findings against the current SDK lifecycle contract. This is report-only; no production, test, proposal, design, specification, or task source was modified.

## Verified Remediations

- **Connect A gates Connect B across recreation.** The coordinator, rather than a panel model, owns the exact Connect Task. Ordinary disappearance moves the shared entry to Cancelling, and synchronous phase delivery makes a replacement panel disable Connect until A's exact completion (`design.md:60-70`; `specs/sdk-ui/spec.md:45-71`).
- **Cancel is unambiguous and reachable.** Connecting exposes one Cancel-labeled action whose defined effect is the same explicit Disconnect preemption route. It cancels the exact Connect, starts or joins one Disconnect, and displays Disconnecting (`design.md:64,72`; `specs/sdk-ui/spec.md:51,58-61,73-75`).
- **The operation bound is structurally expressible.** A per-controller entry contains at most one Connect Task and, only during explicit preemption, one code-free Disconnect Task. Repeated panels/actions reuse the entry, and no model, waiter list, or callback list is captured (`design.md:60-68,86-90`; `specs/sdk-ui/spec.md:45-51`).
- **Ordinary disappearance does not automatically disconnect an active session.** It unregisters the model and only cancels an exact still-owned pending Connect; it does not start Disconnect. An already active connection remains host-owned (`design.md:56,66`; `specs/sdk-ui/spec.md:17-29,51`).
- **Action and observation authority remains exact.** Model generations gate status/action delivery, coordinator registrations are identity-checked, and an old unregister cannot remove the replacement observer (`design.md:56,60-70`; `specs/sdk-ui/spec.md:49,117-130`).
- **Earlier public-state, error, fixture, and UTF-8 findings remain resolved.** The conservative total action matrix, status-never-clears-action-error winner rule, direct `NearWire` test dependency, and exhaustive scalar-prefix matrix remain present (`design.md:72,78,94-103`; `tasks.md:15-19`).
- **Fail-closed cleanup remains bounded.** A nonreturning Disconnect retains one code-free shared operation for the sole process route; it creates no per-panel Task or waiter (`design.md:68,88-90`; `specs/sdk-ui/spec.md:47-51`).

## Actionable Findings

### 1. P2 / Medium — The test plan does not explicitly prove both preemption completion orders

**Confidence: 9/10**

The normative rule correctly keeps the coordinator in Disconnecting until both the cancelled Connect and the Disconnect Task acknowledge completion (`design.md:64`; `specs/sdk-ui/spec.md:51`). The closed phase can represent either remaining tail. However, the testing tasks name Cancel-as-Disconnect, deduplication, fail-closed hold, stale completion, and the maximum live-operation bound without requiring the two asymmetric barriers (`tasks.md:17-18`). A test where both Tasks are released together does not prove that the first acknowledgement cannot prematurely return the entry to idle, admit Connect B, discard the second handle, or remove the entry.

**Required remediation:** require two deterministic tests. In the first, acknowledge Connect while Disconnect remains held; in the second, acknowledge Disconnect while Connect remains held. In both, assert the phase remains Disconnecting, Connect B is rejected, the remaining exact handle/retention is unchanged, duplicate/stale acknowledgements are inert, and only the second exact acknowledgement returns/removes the entry. Retain the existing fail-closed case where the Disconnect acknowledgement never arrives.

### 2. P2 / Medium — A replaced observer slot leaves a simultaneously visible older panel with stale actions

**Confidence: 8/10**

The coordinator deliberately retains one replaceable observer and synchronously gives the current phase to the newest registration (`design.md:60,70,88`; `specs/sdk-ui/spec.md:49`). Exact registration identity correctly prevents the older panel from unregistering the replacement. But the supported public API does not limit an App to one simultaneously visible `NearWireConnectionView` for an injected instance. If panel A remains visible and panel B registers, A stops receiving coordinator phase changes. It can continue to display Connect after B starts Connect, Cancel after B preempts, or Disconnecting after the coordinator returns idle. Coordinator admission prevents duplicate Tasks, but the older public view no longer satisfies the total action-presentation rule and receives no result explaining the rejected activation.

The planned “repeated registration/start/stop” and observer-slot probes do not define or assert the displaced live panel's presentation (`tasks.md:17-18`). Rapid replacement is safe because the old model disappears; simultaneous presentation is the unresolved case.

**Required remediation:** define a bounded displaced-observer behavior. Options include documenting and enforcing one live connection panel per exact instance, synchronously revoking the prior observer into a fixed disabled “Controlled in another panel” presentation before replacement, or using another bounded shared-state observation mechanism that keeps every supported live panel coherent. Add a two-live-panel test covering replacement, operation start, preemption, both completions, old-panel action activation, exact unregister in both orders, and model release.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check -- openspec/changes/sdk-ui`: PASS.

## Verdict

**Unresolved actionable finding count: 2 — 2 Medium. Pre-implementation correctness/testing approval is not granted.**

The coordinator redesign closes the prior High-severity cancellation, recreation, action-reachability, and hard-bound defects. Approval now depends on explicit dual-acknowledgement barrier coverage and a defined coherent behavior for a displaced but still-visible panel.
