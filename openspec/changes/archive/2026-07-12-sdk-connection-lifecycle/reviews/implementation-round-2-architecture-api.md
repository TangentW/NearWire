# Implementation Architecture and API Review — Round 2

## Scope

Reviewed the current remediated production source, public API models, lifecycle orchestration tests, documentation, OpenSpec design/specifications/tasks, evidence, and the Round 1 architecture/API report for `sdk-connection-lifecycle`. The latest phase-aware recovery changes and 44-test focused suite were re-read after the final source/test update. This review is report-only; no production, test, specification, evidence, or documentation source was modified.

## Round 1 Finding Disposition

### P1 suspend/resume authorization race — resolved

The actor now owns an exact `SDKLifecycleCommandToken`, advances and writes the intent generation on suspension, and admits post-cleanup publication/scheduling only from the token-current command (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:7-10`; `SDK/Sources/NearWire/NearWire.swift:1327-1363`). Resume records the single Boolean only while that exact cleanup command exists (`SDK/Sources/NearWire/NearWire.swift:1367-1387`). A cancelled held delay therefore fails the changed generation check, and a stale suspend continuation fails the command-token check instead of overwriting its successor (`SDK/Sources/NearWire/NearWire.swift:1176-1228,1344-1350`).

The new barriers cover resume during active-route release, non-cooperative held sleep, and a recovery attempt; they prove no early claim, a reset attempt-one campaign, preserved intent, and coherent successor state (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1089-1228`).

### P2 explicit-connect precedence — partially resolved

Recovery delay and actor-command cleanup now precede slot/intent checks and return `connectionInProgress` (`SDK/Sources/NearWire/NearWire.swift:209-226`). The added recovery-delay and disconnect-cleanup tests validate those two previously missing cases without starting validation or connection side effects (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1029-1087`). One residual cleanup phase remains below.

## Finding

### P2 — Medium: Spontaneous active-terminal cleanup is still reported as `alreadyConnected`

The exact preflight contract places an unresolved cleanup before an active route, with `connectionInProgress` before `alreadyConnected` (`openspec/changes/sdk-connection-lifecycle/specs/sdk-connection-lifecycle/spec.md:40-47`; `openspec/changes/sdk-connection-lifecycle/specs/sdk-public-connect/spec.md:3-9`). The remediation recognizes cleanup only through `lifecycleCleanupCommand` or `recoveryTask` (`SDK/Sources/NearWire/NearWire.swift:209-226`).

When an active transport terminates spontaneously, the terminal coordinator can already be waiting at `beforeRelease`, releasing the lease, or waiting at `beforeTerminalDelivery`, while the actor still retains the `.active` slot. It provides no pre-release cleanup signal to the actor; actor delivery happens only after release and both hooks (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:216-235`; `SDK/Sources/NearWire/NearWire.swift:1037-1067`). An explicit connect during that interval therefore sees no command or recovery Task and returns `alreadyConnected`, although exact cleanup is in progress and its receipt remains unresolved. The existing terminal-release barrier proves the interval but does not call explicit connect within it (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:620-648`).

Action: make spontaneous terminal cleanup actor-visible with an exact route/token-owned cleanup phase before release begins, without publishing disconnected or permitting successor work before receipt settlement. Include that phase in the preflight `connectionInProgress` check and clear it only through exact post-release delivery. Add a deterministic test that holds `beforeRelease`, supplies an invalid new code, and proves `connectionInProgress` wins with no new identity, discovery, or lease claim.

## Additional Architecture/API Recheck

- Phase-aware production routing now preserves `.recoveryAttempt` for both directly thrown admission errors and terminal gate failures (`SDK/Sources/NearWire/NearWire.swift:885-975,1218-1267`). The production pre-active transport-failure test proves a maximum-two campaign stops after its first replacement (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1291-1319`).
- Pending-to-active intent identity, intent-wide attempt accounting, exact receipt settlement, stale generation isolation, fresh lease/route construction, status coherence, shutdown precedence, and default-disabled behavior remain aligned with the approved specifications.
- Public policy, status, disconnect, suspend, and resume APIs remain source-compatible in Swift 5 language mode and expose no implementation ownership types.
- No architecture/API scope expansion or new runtime dependency was found.

## Validation

- `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: passed, 44 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Changes required. Unresolved actionable findings: 1 medium. Architecture/API approval remains withheld until spontaneous terminal cleanup participates in the exact preflight precedence and a fresh review is clean.**
