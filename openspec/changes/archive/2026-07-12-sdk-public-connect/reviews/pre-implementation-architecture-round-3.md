# Pre-Implementation Architecture and API Review — Round 3

## Scope Reviewed

Fresh review of the revised proposal, design, tasks, and six capability deltas against the current `NearWire` actor, session admission handoff, permanent transport core, active-pump live-operation graph, one-shot terminal observer, exact process lease, public state/error boundary, connection-limit domains, and roadmap items 12 and 13. Round 2 findings were re-proven from the revised normative text and current source rather than assumed resolved.

## Round 2 Resolution Audit

- **Round 2 finding 1, strong active core-to-`NearWire` cycle:** resolved at planning level. `sdk-active-event-pump` is now explicitly modified. The core must remove `activeOwner`, capture App rates by value, and make clock, wake, scheduling, drain, and publication operations weak-owner-aware (`design.md:147-151`; `specs/sdk-active-event-pump/spec.md:3-25`; `specs/sdk-public-connect/spec.md:124-132`; `tasks.md:22,24`). This directly covers both current strong paths: `SDKSessionTransportCore.activeOwner` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:202-205,521-529`) and the owner-capturing closures in `SDKActiveLiveOperations` (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:137-224`). The refactor is feasible: rates are immutable configuration values, owner-dependent operations already have closed owner-unavailable outcomes or can be extended to return one, wake registration is actor-owned storage, and the handle's existing deinitializer remains the cancellation trigger.
- **Round 2 finding 2, no unique terminal owner across admission and activation:** resolved at ownership-model level. Admission now creates one `SDKSessionLifetime`; admitted session, attachment, and active handle share the same relay and termination value; one coordinator starts the sole wait before attachment and exclusively owns the lease and release gate; later owners neither replace the termination value nor register another wait (`design.md:119-145`; `specs/sdk-public-connect/spec.md:106-122`; `specs/sdk-process-connection-lease/spec.md:3-9`; `specs/sdk-session-admission/spec.md:14-24`; `tasks.md:21,23-25`). This is implementable by replacing the current relay-only admitted/attachment handoff (`SDKSessionTransportCore.swift:9-104`) and the active handle's replacement termination construction (`SDKActiveEventPump.swift:285-339`) with the shared lifetime. The current core already permits a termination wait before attachment and returns a latched terminal result to a late waiter (`SDKSessionTransportCore.swift:363-373,685-713`). One remaining terminal-versus-connected-commit linearization gap is reported below; it does not reopen sole wait or lease ownership.
- **Round 2 finding 3, pending shutdown error:** resolved. A token-current shutdown before the actor connected commit now overrides Task cancellation and all lower-layer results and returns `NearWireError.shutdown`; task-only cancellation before transfer returns `connectionCancelled`; a shutdown after the indivisible connected commit does not rewrite successful return (`design.md:21-33`; `specs/sdk-public-connect/spec.md:3-25`; `tasks.md:23`).

## Findings

### 1. P1 / High (confidence: 9/10) — The terminal winner table has no shared linearization point with the actor's connected commit

**Evidence**

- The normative table requires terminal-after-transfer-before-actor-commit to fail `connect`, while actor-commit-before-terminal must return success (`design.md:127-139`; `specs/sdk-public-connect/spec.md:108-112`). The terminal coordinator is described as storing the terminal code only when its asynchronous wait completes and then sending a weak actor callback (`design.md:123-125`).
- The attempt's lock-linearized state covers task/shutdown cancellation, target generations, and active transfer, but it does not share a terminal/commit gate with the coordinator (`design.md:56-67`; `specs/sdk-public-connect/spec.md:86-95`). The coordinator owns a “terminal flag,” yet no requirement makes the actor claim connected commit through that same lock or makes a terminal store atomic against that claim.
- In the current source, core terminal state resumes the one pending termination continuation (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1914-1922`). Resuming that continuation schedules the coordinator Task; it does not synchronously run the Task's terminal-code store before the suspended actor `connect` Task may resume. Therefore even a pre-commit flag check can observe open, then race a terminal store before owner/state commit. More strongly, the core can already be terminal while the coordinator Task has not run at all.
- Named barriers around terminal delivery and actor commit make the ordering reproducible, but barriers do not create the missing mutual exclusion (`design.md:69-84`; `tasks.md:17,23`).

**Impact**

A conforming-looking implementation can commit `connected` and return success after the permanent core is already terminal, or after terminal wins between a non-atomic flag check and the actor commit. The result contradicts the winner table, makes pre-return terminal mapping scheduling-dependent, and can briefly install a dead connected owner even though lease release is already proceeding.

**Required remediation**

Define one synchronous, lock-linearized terminal-versus-connected-commit gate shared by the session lifetime, coordinator, and actor commit. The lifetime's terminal authority must mark the exact terminal code synchronously when the core becomes terminal, before merely resuming the async waiter. The actor must call one `claimConnectedCommit()` operation in its no-suspension commit turn; that claim either records commit-won or returns the already-terminal code. Core terminal marking and commit claim must use the same gate, with no check-then-commit gap. Define “actor commit” in the table as that successful claim followed by owner installation, connected publication, and method return in the same actor turn. Preserve the coordinator as the only async waiter and lease owner; the shared gate is terminal state, not a second wait.

Add deterministic tests for terminal marking immediately before and after the commit claim, including delayed coordinator-Task scheduling and delayed weak callback delivery. Assert exact public result, state sequence, connected-owner installation count, cancellation count, one wait, one release, and later-claim eligibility for both winners. Add the gate/mark/claim boundaries to tasks 3.1, 3.5, 3.7, and the state/ownership linearization evidence in task 4.5.

## Re-Audit Notes

- **Scope and roadmap:** the change remains a narrow item 12 orchestrator. Breaking the active-pump retain cycle and adding terminal-safe lease cleanup are required to make one public connect safe; public disconnect, reconnect, retained-code policy, background behavior, route replacement, and terminal-reason history remain item 13 (`proposal.md:7-13,29-31`; `design.md:5-9,173-175`).
- **Public API and error boundary:** `connect(code:)` remains the only new operation. Public errors are closed, fixed, content-safe, and limited to failures observable before success; post-success terminal causes only publish disconnected (`specs/sdk-public-connect/spec.md:134-145`; `specs/sdk-public-boundary/spec.md:12-27`). No internal lifetime, coordinator, lease, Network, or Security type crosses the supported API.
- **Lease timing:** the attempt owns the exact lease through identity and admission; the coordinator owns it from admission through core terminal and releases only after terminal. Public detachment does not create a claimable gap, and runtime synchronization failure remains fail-closed (`design.md:141-145`; `specs/sdk-process-connection-lease/spec.md:5-29`).
- **Weak wake cleanup:** the revised contract is compatible with current actor-owned `outboundWakeRegistration` storage (`SDK/Sources/NearWire/NearWire.swift:92,446-481`). When the actor exists, weak live operations can remove the exact token; after deinitialization, destruction of that storage releases the callback, so terminal cleanup must not attempt an unavailable actor hop. The required retain-graph and deinitialization tests cover this distinction.
- **Limit planner:** the fixed network Event-record maximum is now independent of offline queue accounting, uses checked constant-space arithmetic, distinguishes every downstream byte domain, and requires production-encoder structural/property evidence (`design.md:35-54`; `specs/sdk-public-connect/spec.md:27-48`; `tasks.md:10-13`). This is feasible with the existing deterministic `JSONValue` content and `WireEventRecord` encoders; no synthetic maximum allocation is required at connect time.
- **Dependency seam and pairing lifetime:** immutable internal dependencies and content-free barriers are sufficient for deterministic race tests without exposing test hooks publicly (`design.md:69-84`). Pairing ownership ends in public orchestration after admission construction and in admission when discovery takes ownership; no active or terminal owner retains it (`design.md:105-111`; `specs/sdk-public-connect/spec.md:77-84`).

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Static feasibility audit against current active-owner storage and closures, admitted/attachment relay ownership, active-handle termination construction, core termination waiter registration/resumption, process lease deinitialization, wake storage, public state/error types, deterministic content/wire encoders, and roadmap items 12 and 13.

## Unresolved Count

**1 unresolved finding: 1 High. Architecture/API planning closure is not granted.**
