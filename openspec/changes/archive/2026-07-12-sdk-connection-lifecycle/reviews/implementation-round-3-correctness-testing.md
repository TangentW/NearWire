# Implementation Correctness and Testing Review — Round 3

## Scope

Re-reviewed the latest production source, lifecycle tests, OpenSpec requirements/tasks, and evidence. This round focused on latest-command status for disconnect/suspend ordering, spontaneous terminal cleanup preflight, exact cleanup-marker clearing, shutdown and stale callbacks, and all previously remediated recovery races. No production or test source was modified.

## Prior-Finding Disposition

The Round 2 status finding is resolved. Active terminal presentation now reads the actor's current suspension latch even after a prior disconnect cleared intent (`SDK/Sources/NearWire/NearWire.swift:1104-1113`). Deterministic held-release tests cover both command orderings and assert every delivered status value:

- Disconnect followed by suspension remains suspended through terminal delivery and finishes suspended (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1326-1365`).
- Suspension followed by disconnect remains not suspended after the later disconnect and finishes not suspended (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1367-1409`).

## Targeted Verification

- The coordinator announces spontaneous terminal cleanup before release. The actor installs the marker only for the exact current token and receipt; delivery clears only the same pair before route mutation (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:223-245`; `SDK/Sources/NearWire/NearWire.swift:1047-1078`).
- Explicit connect rejects lifecycle-command cleanup, spontaneous terminal cleanup, and recovery delay before input validation or lease work (`SDK/Sources/NearWire/NearWire.swift:207-220`). The held spontaneous-release test proves no second claim or identity load occurs (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:620-654`).
- Shutdown clears the cleanup command and spontaneous marker, removes the route slot, invalidates intent/generation, and publishes one final status. Exact stale delivery can settle its captured receipt but cannot mutate shutdown state or a replacement marker (`SDK/Sources/NearWire/NearWire.swift:1456-1484`).
- Resume-before-cleanup remains single-owner across active route, held delay, and in-flight recovery attempt. Generation checks prevent stale attempts, the cleanup-command token prevents stale continuations from publishing, and attempt-one budget/status assertions remain deterministic (`SDK/Sources/NearWire/NearWire.swift:1151-1292,1345-1442`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1094-1233`).
- Phase-aware recovery retains internal code and origin through direct and terminal-gate failure paths. The exhaustive mapping and production pre-active transport test prove permanent failure clears intent without an extra claim (`SDK/Sources/NearWire/NearWire.swift:958-985,1268-1323`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:905-938,1296-1324`).

## Remaining Findings

None. No material correctness or testability regression was found.

## Validation

- `swift test --package-path . -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: PASS — 46 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS — `Change 'sdk-connection-lifecycle' is valid`.
- `git diff --check`: PASS.

## Verdict

**Unresolved actionable finding count: 0. Implementation correctness/testing approval is granted.**
