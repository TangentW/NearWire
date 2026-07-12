# Implementation Correctness and Testing Review — Round 2

## Scope

Re-reviewed the latest remediated production source, lifecycle tests, OpenSpec requirements/tasks, and evidence. This round re-tested all four Round 1 findings, resume-before-cleanup winner orders, status coherence, campaign budget/delay, stale completion isolation, cleanup receipts, and the phase-aware recovery-failure wrapper. No production or test source was modified.

## Round 1 Finding Disposition

All four Round 1 findings are resolved:

1. **Held recovery delay after suspend/resume:** suspension now advances the retained intent generation, and stale delay completion cannot pass the generation guard. The cleanup command remains present until cancellation acknowledgement, then one fresh attempt-one campaign is scheduled (`SDK/Sources/NearWire/NearWire.swift:1348-1387`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1137-1182`).
2. **Resume during an in-flight recovery attempt:** the changed intent generation prevents the cancelled attempt's failure continuation from clearing retained intent; the current cleanup command alone consumes the Boolean request and starts one successor (`SDK/Sources/NearWire/NearWire.swift:1237-1266,1348-1387`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1184-1228`).
3. **Active-route cleanup presentation overwrite:** terminal delivery defers successor scheduling while a cleanup command exists, and the current suspension command finalizes disconnected before starting recovery. The held-delay assertion proves reconnecting/attempt-one status survives after suspension returns (`SDK/Sources/NearWire/NearWire.swift:1073-1091,1348-1387`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1089-1135`).
4. **Old terminal error carried into a new explicit attempt:** explicit discovering and connecting publications now clear `lastError` and retry progress; current and late-subscriber assertions cover both phases (`SDK/Sources/NearWire/NearWire.swift:415-422,867-881`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1230-1289`).

The recovery pipeline now preserves closed internal code and phase through `SDKLifecycleRecoveryFailure`, including terminal gate failures, before public mapping. The exhaustive wrapper table and a production max-two campaign test prove that pre-active `transportFailed` is permanent and does not schedule attempt two (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:67-116`; `SDK/Sources/NearWire/NearWire.swift:948-975,1237-1247`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:900-933,1291-1319`).

## Actionable Finding

### 1. P2 / Medium — A later suspension can be transiently undone by the old active-route callback

**Confidence: 9/10**

If `disconnect()` starts first, it clears active intent and waits for the route receipt (`SDK/Sources/NearWire/NearWire.swift:1315-1338`). A later `suspendConnection()` supersedes the cleanup command and latches `isConnectionSuspended = true` while awaiting the same route (`SDK/Sources/NearWire/NearWire.swift:1348-1373`). When old terminal delivery arrives, `handleActiveTerminal` takes its no-intent branch before consulting the current cleanup command and hard-codes `isSuspended: false` (`SDK/Sources/NearWire/NearWire.swift:1073-1082`). Until the suspended continuation publishes its final value, `connectionStatus` can therefore report disconnected/not-suspended even though the latest actor command has latched suspension. This is a stale status mutation from the older route and contradicts the canonical suspended outcome and stale-callback status isolation (`specs/sdk-connection-lifecycle/spec.md:54-70,126-132`).

No deterministic test covers disconnect-then-suspend and suspend-then-disconnect against one held active-route release; the new tests cover resume against active cleanup, delay cleanup, and recovery-attempt cleanup only.

**Required fix:** make the no-intent terminal presentation use the actor's current suspension latch, or route all post-release presentation through the current cleanup command token. Add both command orderings with a release barrier and status-stream/current-snapshot assertions, proving the later command's suspension value never regresses after terminal delivery.

## Validation

- `swift test --package-path . -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: PASS — 44 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS — `Change 'sdk-connection-lifecycle' is valid`.
- `git diff --check`: PASS.

## Verdict

**Unresolved actionable finding count: 1 — 0 High, 1 Medium. Implementation correctness/testing approval is not yet granted.**

The four Round 1 defects and phase-aware recovery behavior are resolved. Approval requires only the remaining disconnect/suspend terminal-status winner order to preserve the latest command's suspension value and gain deterministic coverage.
