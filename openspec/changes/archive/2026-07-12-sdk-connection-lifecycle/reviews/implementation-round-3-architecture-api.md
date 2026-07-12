# Implementation Architecture and API Review — Round 3

## Scope

Reviewed the latest remediated production source, public API models, lifecycle orchestration tests, documentation, OpenSpec design/specifications/tasks, evidence, and the Round 1–2 architecture/API reports for `sdk-connection-lifecycle`. This review is report-only; no production, test, specification, evidence, or documentation source was modified.

## Prior-Finding Disposition

The remaining Round 2 explicit-connect precedence finding is resolved.

- The terminal coordinator now awaits `cleanupStarted` immediately after successful terminal observation and before the `beforeRelease` hook or lease release invocation (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:223-243`).
- The production connection pipeline binds that callback to the exact route token and cleanup receipt (`SDK/Sources/NearWire/NearWire.swift:505-524`).
- The actor installs `spontaneousTerminalCleanup` only when both token and receipt match the current attempt or active slot (`SDK/Sources/NearWire/NearWire.swift:1047-1061`). A stale callback cannot mark a different route.
- Explicit preflight checks lifecycle-command cleanup, exact spontaneous-terminal cleanup, and recovery work before attempt/active slot and retained-intent ownership, so a held spontaneous cleanup returns `connectionInProgress` before validating a new code (`SDK/Sources/NearWire/NearWire.swift:207-235`).
- Post-release terminal delivery settles the receipt and clears the spontaneous marker only on the same token-and-receipt identity before applying the current slot transition (`SDK/Sources/NearWire/NearWire.swift:1063-1101`). Release and `afterRelease` therefore precede marker clearance.
- The held `beforeRelease` test now asserts `connectionInProgress` for invalid input and proves no second lease claim or identity load occurs (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:620-654`).

The Round 1 suspend/resume authorization finding also remains resolved: exact cleanup-command ownership, intent-generation invalidation, and deferred-resume consumption still prevent cancelled or stale work from authorizing or overwriting a successor (`SDK/Sources/NearWire/NearWire.swift:1345-1443`). The active-cleanup, held-delay, and recovery-attempt barriers remain intact, and the two latest command-order tests additionally prove that only the newest disconnect/suspend command publishes final suspension state (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1094-1228,1326-1409`).

## Architecture/API Regression Scan

No actionable regression was found.

- Pending and active intent ownership remains actor-local and uses the same intent token across connected commit.
- Lifecycle command tokens govern command completion; route token plus receipt identity govern terminal cleanup and settlement; intent generation separately governs successor authorization. These ownership domains remain distinct.
- Recovery retains its intent-wide budget, code-free weak delay Task, phase-aware production failure routing, exact release-before-replacement ordering, and fresh route composition.
- Status and state updates remain actor-coherent, with stale command continuations unable to regress the latest command's suspension result.
- Exact explicit-connect precedence is now complete for recovery delay/attempt, actor-command cleanup, spontaneous terminal cleanup, active route, and retained intent.
- Public policy, status, disconnect, suspend, and resume APIs remain Swift 5 language-mode compatible and expose no internal token, receipt, lease, route, or recovery type.
- No third-party runtime dependency or out-of-scope product behavior was introduced.

## Validation

- `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: passed, 46 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Unresolved actionable findings: 0. Approved from the architecture/API perspective.**
