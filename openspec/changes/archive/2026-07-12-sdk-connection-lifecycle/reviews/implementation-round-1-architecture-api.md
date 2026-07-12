# Implementation Architecture and API Review — Round 1

## Scope

Reviewed the production implementation, public API models, lifecycle orchestration tests, documentation, OpenSpec proposal/design/specifications/tasks, and current evidence for `sdk-connection-lifecycle`. This review is report-only; no production, test, specification, or documentation source was modified.

The supported policy/status APIs, actor-owned pending-to-active intent promotion, exact cleanup receipt, phase-aware recovery mapping, fresh-route pipeline reuse, and Swift 5 language-mode distribution boundaries are broadly consistent with the approved design. The two lifecycle ownership gaps below block approval.

## Findings

### P1 — High: Resume can reauthorize cancelled suspension work and a stale suspend continuation can overwrite its successor

`suspendConnection()` invalidates only `lifecycleGeneration`, cancels a captured delay/route, and then awaits its receipt or Task before unconditionally publishing a final state (`SDK/Sources/NearWire/NearWire.swift:1253-1287`). `resumeConnection()` can clear the suspension latch during that await and records only the Boolean deferred request (`SDK/Sources/NearWire/NearWire.swift:1291-1304`), but neither the Boolean nor the suspended operation has an exact command/campaign token.

This leaves two violating actor interleavings:

1. For an active route, terminal delivery settles the receipt, consumes the deferred Boolean, and schedules recovery (`SDK/Sources/NearWire/NearWire.swift:982-1033`). The older suspended call can then resume and overwrite the current recovery presentation with `disconnected` (`SDK/Sources/NearWire/NearWire.swift:1269-1287`). Recovery may therefore own a delay or attempt while public state is no longer `reconnecting`.
2. For a held non-cooperative recovery sleeper, suspension increments `lifecycleGeneration` but does not change `connectionIntent.generation` and leaves the cancelled Task installed while awaiting it (`SDK/Sources/NearWire/NearWire.swift:1258-1272`). If resume clears the latch before that sleeper returns, `runScheduledRecovery` still accepts the old Task because it checks only Task identity, suspension, and the unchanged intent generation (`SDK/Sources/NearWire/NearWire.swift:1123-1157`). The cancelled campaign can claim a fresh route; after it completes, the older suspended call can publish `disconnected` over that active route.

Both paths violate the required cancellation-completion handshake, generation-current successor authority, and the requirement that recovery remain `reconnecting` through delay/admission (`openspec/changes/sdk-connection-lifecycle/specs/sdk-connection-lifecycle/spec.md:77-98,126-132,149-159`). They also contradict the current route/resource audit claims that cancelled delay work fails authorization and cannot claim (`openspec/changes/sdk-connection-lifecycle/evidence/route-lease-chronology-audit.md:11-17`; `openspec/changes/sdk-connection-lifecycle/evidence/retention-resource-audit.md:5-8`).

Action: add exact suspension/campaign authorization distinct from retained intent generation. Cancelled delay Tasks must remain retained only as cleanup owners and must fail successor authorization even if resume clears the latch. The post-cleanup path that owns the exact suspension token should be the sole consumer of the Boolean and the sole publisher/scheduler; stale `suspendConnection()` continuations must not mutate a newer route or recovery campaign. Add deterministic tests for (a) resume while active-route release is held and (b) suspend/resume while a non-cooperative recovery sleep is held, asserting no early claim, exactly one attempt-one successor, coherent `reconnecting` state, and no stale post-success overwrite.

### P2 — Medium: Explicit-connect preflight does not implement the specified recovery-delay and cleanup precedence

The fixed public precedence requires a current recovery delay/attempt or unresolved cleanup to return `connectionInProgress` before considering an active route or retained intent (`openspec/changes/sdk-connection-lifecycle/specs/sdk-connection-lifecycle/spec.md:40-47`; `openspec/changes/sdk-connection-lifecycle/specs/sdk-public-connect/spec.md:3-9`). The implementation checks only `connectionSlot`, then `connectionIntent` (`SDK/Sources/NearWire/NearWire.swift:204-223`):

- During a recovery delay, `connectionSlot` is nil while `recoveryTask` and active intent exist, so explicit connect returns `connectionIntentExists` instead of `connectionInProgress`.
- During active-route disconnect cleanup, intent is cleared while the active slot/receipt remains until release (`SDK/Sources/NearWire/NearWire.swift:1221-1242`), so explicit connect returns `alreadyConnected` instead of `connectionInProgress`.

The focused tests cover an attached initial attempt (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:307-321,392-409`) and retained disconnected intent (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:651-681`), but not either missing precedence phase. Consequently, the evidence matrix's claim of explicit-connect precedence coverage is incomplete (`openspec/changes/sdk-connection-lifecycle/evidence/requirement-to-evidence.md:5-9`).

Action: represent recovery-delay and cleanup-in-progress ownership explicitly enough to distinguish them from a healthy active route, apply the exact preflight order, and add barrier tests that assert the precise public error without validating the supplied code or starting identity/discovery/lease work.

## Validation

- `swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: passed, 37 tests, 0 failures. The passing suite does not exercise the interleavings or precedence phases identified above.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Changes required. Unresolved actionable findings: 2 (1 high, 1 medium). Architecture/API approval is withheld until both findings are fixed, affected evidence is corrected, and a fresh review round is clean.**
