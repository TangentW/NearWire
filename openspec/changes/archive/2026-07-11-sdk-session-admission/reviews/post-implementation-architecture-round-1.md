# Post-Implementation Architecture Review — Round 1

## Scope

Reviewed the complete current uncommitted diff and the active change proposal, design, capability specifications, and tasks. The review focused on authority transfer, cancellation ordering, Core/SDK visibility, permanent callback and transport ownership, actor and relay lifetime, production discovery/transport composition, residual scope, and Swift 5 strict-concurrency compatibility.

## Findings

### P1 — Cancellation can be lost during discovery-to-core authority transfer

**Severity:** P1 (correctness and lifecycle authority)

**Evidence:**

- `openspec/changes/sdk-session-admission/design.md:50-52,67,87` requires authority to transfer exactly once before channel construction, after which cancellation must be tokenized and ordered by the permanent transport core.
- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:29-31` requires the result waiter and opaque attempt token to transfer on exact discovery match and makes the core the sole authority from `connecting` onward.
- `openspec/changes/sdk-session-admission/tasks.md:11` marks that exact authority transfer and invalidatable attempt token as complete.
- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:142-168` ends discovery ownership, creates the core and channel, and then performs a cross-actor `await transportCore.bind(channel:)` while the admission actor still reports `.discovering` and retains no core/token authority.
- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:71-87` therefore handles cancellation during that actor-hop window as discovery cancellation. Discovery has already been cleared at line 143, so the request cannot stop either discovery or the new channel/core.
- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:182-189` subsequently overwrites the cancelled state with `.transferred` without rechecking the cancellation override and starts the core.
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:183-201` does not install the attempt token until `run`; consequently, moving only the admission state/token assignment earlier would still leave pre-`run` core cancellation unable to latch.
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:756-799` covers cancellation before run, during discovery, and after the channel has started, but does not deterministically exercise cancellation after discovery success and before channel/core startup.

**Impact:** A cancelled admission task can still construct and start the secure channel, continue protocol admission, and potentially return an admitted session. This creates a period with no effective terminal authority and contradicts the change's core ownership invariant.

**Actionable remediation:**

1. Atomically record the one-way transfer in `SDKSessionAdmission` immediately after the exact discovery result and before channel construction or any cross-actor suspension: create the attempt token and permanent core, assign `core` and `attemptToken`, and set `.transferred` while clearing admission-owned discovery state.
2. Make the core own/latch the attempt token and cancellation before a channel exists, preferably by supplying the token to the core initializer. `cancelAttempt(_:)` must terminally cancel a transferred-but-not-yet-bound core, and later bind/start work must observe that terminal state and not start the channel.
3. Construct and bind the channel only after transfer, under core authority. Do not let admission overwrite a terminal state after an actor hop.
4. Add a deterministic seam/test that pauses immediately after discovery match but before channel construction/start, cancels the admission task, and proves the result is `.cancelled`, the channel never starts (or is cancelled exactly once if construction has already occurred), and no later state transition revives the attempt.

## Validation Notes

- Swift 5 language mode with `-strict-concurrency=complete -warnings-as-errors` compiled successfully.
- Focused `SDKSessionAdmissionTests` passed: 22 tests, 0 failures.
- `Scripts/check-session-admission-structure.rb` passed.
- `git diff --check` passed.

No additional architecture, visibility-boundary, permanent callback ownership, retain-cycle, production composition, residual-scope, or Swift 5 concurrency findings were identified in this round.
