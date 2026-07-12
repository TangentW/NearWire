# Post-Implementation Correctness and Testing Review — Round 4

## Scope

Performed the final correctness/testing review of the current `sdk-public-connect` worktree. The review rechecked the Round 3 Task 3.7 finding, compared the narrowed evidence commitment against unchanged normative behavior, traced the current tests and source audits to every revised evidence row, reviewed the final lock-local cancellation result fix, and independently reran the focused, full strict-concurrency, aggregate package, strict OpenSpec, and diff gates. No production, test, specification, task, or evidence file was modified.

## Round 3 Finding Resolution

### Task 3.7 is now truthfully scoped

The change no longer promises a both-winner Cartesian product at every asynchronous scheduling point. It now requires:

- both lock-linearized orders for cancellation/target installation and replacement;
- both critical-section winners for terminal versus active-transfer and terminal versus connected-commit;
- deterministic async barriers at admitted result, activation result, phase authorization, shutdown, and release-before-delivery;
- exact-token source/integration audits for stale callbacks and the single coordinator wait/release;
- supported retry outcomes without sleeps.

This wording appears consistently in Task 3.7 (`openspec/changes/sdk-public-connect/tasks.md:23`) and the required-evidence section (`openspec/changes/sdk-public-connect/design.md:177-184`). It narrows only the validation strategy. The normative requirements remain intact:

- the shared gate, exact-generation replacement, stale-owner disposal, and cancellation chronology remain required (`specs/sdk-public-connect/spec.md:86-95`);
- same-gate atomic lease handoff, exactly one coordinator wait, terminal-before-claim behavior, shutdown authority, and one release gate remain required (`spec.md:106-124`);
- stale callbacks remain inert (`spec.md:136-147`);
- cancellation/shutdown racing lifetime handoff must leave exactly one lease owner (`spec.md:149-162`).

No product behavior, ownership guarantee, error precedence, state transition, release condition, or fail-closed rule was weakened.

### The revised evidence commitment is covered

- Target-first cancellation is proven by `testTransitionGateDeliversCancellationOncePerTargetGeneration`; cancellation-first late installation is proven by `testCancellationResultLinearizesBeforeLateTargetInstallation`; stale and exact replacement is proven by `testTransitionGateReplacesOnlyExactTargetGeneration` (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:23-133`).
- Both terminal/active-transfer and terminal/connected-commit critical-section winners are forced with synchronous in-lock barriers (`SDKPublicConnectionOrchestrationTests.swift:135-216`).
- The public async result boundaries cancel and dispose the admitted owner and active handle exactly once, then release exactly once (`SDKPublicConnectionOrchestrationTests.swift:561-618`). Phase authorization and shutdown are independently held and verified before channel/core work (`SDKPublicConnectionOrchestrationTests.swift:373-437`).
- Release is held after terminal evidence and before weak state delivery; the test proves the state remains connected and release count remains zero while held, then proves one release before disconnected delivery (`SDKPublicConnectionOrchestrationTests.swift:620-649`).
- Public terminal delivery is guarded by exact active-token identity, so an old token cannot clear or mutate another slot (`SDK/Sources/NearWire/NearWire.swift:807-813`). Connected commit similarly requires the exact attempt token (`NearWire.swift:789-804`). The supported-connect and final-owner tests exercise these callbacks through real lifetime transitions.
- The public coordinator is the sole public call site that registers the lifetime wait (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:154-167`). The termination object atomically rejects a second registration, and the existing termination test proves the duplicate wait error (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:321-347`; `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:50-59`). Terminal success, wait failure, owner destruction, real-process contention, and facade runtime-failure tests prove release timing and fail-closed behavior.
- Facade release-enter failure proves contention on retry without sleeping; claim-exit and release-exit rows prove their supported public outcomes (`SDKPublicConnectionOrchestrationTests.swift:651-740`).

The new `deliveredAtLinearization` local snapshots the cancellation-delivery result while the gate lock is held, so the returned value no longer reads shared mutable state after unlock (`SDK/Sources/NearWire/Connection/SDKSessionTransitionGate.swift:120-143`). Both preinstalled-target and late-target tests cover the resulting semantics.

## Findings

No correctness, concurrency, race-handling, lease-ownership, retention, test-completeness, or evidence-integrity finding remains.

## Review Status

**Unresolved actionable finding count: 0. Correctness/testing approval is granted.**

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round4-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round4-swiftpm swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnection`: PASS — 38 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round4-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round4-swiftpm swift test --disable-sandbox --quiet -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: PASS — 406 tests, 0 failures.
- Unrestricted `./Scripts/verify-package.sh`: PASS on the reviewed final source:
  - process-lease structural and multi-image gates passed;
  - package, consumer, API, and ownership boundaries passed;
  - iOS result: 406 total, 402 passed, 4 platform skips, 0 failures;
  - Core harness: 196 tests, 0 failures;
  - internal production TLS admission: 1 test, 0 failures, not skipped;
  - supported public-connect production TLS: 1 test, 0 failures, not skipped.
- The preserved package summary reports the same 406/402/4 counts and both TLS gates, and its SHA-256 matches `evidence/logs/SHA256SUMS`.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- `git diff --check`: PASS.
