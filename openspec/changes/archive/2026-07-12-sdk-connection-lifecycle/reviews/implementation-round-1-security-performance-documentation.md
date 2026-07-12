# SDK Connection Lifecycle Implementation Round 1 Security, Performance, and Documentation Review

## Result

**Unresolved actionable finding count: 2** — one Medium and one Low.

The implementation preserves several important boundaries: the delay Task captures no pairing code, automatic recovery has an intent-wide maximum of 20 attempts, replacement uses the existing mandatory-TLS pipeline, accepted bytes are not explicitly requeued, public errors remain fixed and content-safe, and the production diff adds no lifecycle observer, persistence, entitlement, product, pod subspec, or third-party dependency. One High race found during this review was repaired before the report was finalized; the remaining findings below still prevent completion approval.

## Resolved During Review

### Suspension/resume stale-generation race — Resolved

**Evidence**

- The original implementation incremented only a global counter during suspension while old recovery catches compared the unchanged intent generation. Resume-before-cleanup could therefore clear the suspension latch and let the old cancellation clear the retained intent.
- The current source makes intent generation mutable, rotates it when suspension invalidates work, rotates it again when an explicit campaign is reset, and requires the exact generation in the old delay/result paths (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:17-21`; `SDK/Sources/NearWire/NearWire.swift:1087-1090,1159-1206,1296-1335`).
- A tokenized lifecycle cleanup command now prevents an older suspended/disconnect continuation from publishing over a newer command, and deferred resume waits for that exact cleanup owner (`SDK/Sources/NearWire/NearWire.swift:1262-1335,1338-1359`).
- Deterministic tests now cover resume during active-route cleanup, a held recovery delay, and an in-flight recovery attempt, including preservation of one intent and exactly one successor (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1077-1215`).

**Impact**

The stale cancellation can no longer pass freshness checks or clear the newly authorized intent. The source-level defect is resolved.

**Recommended change**

No further action is required for this Round 1 defect. The final validation refresh must retain these passing tests.

## Findings

### 1. Medium — The exhaustive phase-aware disposition table is bypassed by actual recovery-attempt failures

**Evidence**

- `SDKLifecycleRecoveryMapping` defines the required exhaustive `(internal code, phase)` decision and correctly distinguishes pre-active `transportFailed` from `remoteClosed` (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:66-105`).
- Production calls that table only for active-route terminal delivery (`SDK/Sources/NearWire/NearWire.swift:1056-1074`). A recovery attempt first maps its internal failure to a public `NearWireError`, then later makes a second disposition decision from the public error code (`SDK/Sources/NearWire/NearWire.swift:445-467,1199-1258`).
- The exhaustive test invokes the internal phase table directly but does not drive those codes through the production recovery failure path (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:900-921`).
- The normative requirement says every closed internal code plus origin phase maps exhaustively to the disposition that controls retry, and Task 4.1 is already checked (`specs/sdk-connection-lifecycle/spec.md:105-124`; `tasks.md:21`).

**Impact**

The two tables happen to agree for today's codes, so this review did not observe an immediate TLS retry or downgrade. However, the security-critical phase distinction is not what production recovery executes. A later safe-public-error grouping change can silently make a deterministic TLS/invariant failure retry, while the current exhaustive test continues to pass against unused recovery-phase logic.

**Recommended change**

Carry a closed internal recovery result containing both the safe public error and the disposition, or invoke `SDKLifecycleRecoveryMapping` before erasing the internal code. Keep a separate closed mapping only for non-admission failures such as lease/configuration failure. Test every internal code through the real recovery result handler, asserting disposition, intent retention/clearing, next-attempt creation, and that TLS-like transport failure never retries or falls back to plaintext.

### 2. Low — The lease documentation still says only explicit connect can claim

**Evidence**

- `Documentation/SDK-Connection-Lease.md:3` says only explicit `connect(code:)` claims the process lease.
- The next paragraph says both public connect and lifecycle recovery compose the lease, which matches the implementation (`Documentation/SDK-Connection-Lease.md:5`; `SDK/Sources/NearWire/NearWire.swift:1171-1189,199-295`).

**Impact**

The same authoritative document gives contradictory ownership guidance and can mislead maintainers auditing whether automatic work may touch the process-wide lease.

**Recommended change**

State that only an explicit connect or one generation-current lifecycle recovery attempt may claim the lease, and update the later “first time it explicitly claims” wording in the same document to cover recovery claims.

## Evidence Status

The change now contains a requirement-to-evidence matrix, route/lease chronology audit, retention/resource audit, run identity, and validation summary. They document the one-code-owner, code-free weak-self delay Task, constant-space receipt, bounded flapping budget, no-replay, production TLS, package, CocoaPods, observer, persistence, and dependency checks (`evidence/requirement-to-evidence.md:1-15`; `evidence/retention-resource-audit.md:1-11`; `evidence/validation-gates.md:1-22`). The validation summary correctly says a fresh final package run remains required after implementation-review remediation, and Tasks 6.1 through 6.4 remain unchecked; this is outstanding completion work rather than an additional Round 1 implementation finding.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-lifecycle-review-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-lifecycle-review-swiftpm swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: PASS — 43 tests, 0 failures, including the repaired suspend/resume winner orders.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS — `Change 'sdk-connection-lifecycle' is valid`.
- `git diff --check`: PASS.

## Final Verdict

**Not ready for completion.** The High race found during this review is fixed and covered. Route actual recovery failures through the normative phase-aware disposition, correct the lease documentation, complete the fresh final lifecycle/resource/TLS/package gates, and obtain a fresh review round.
