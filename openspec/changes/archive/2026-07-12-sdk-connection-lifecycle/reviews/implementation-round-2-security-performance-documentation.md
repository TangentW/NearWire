# SDK Connection Lifecycle Implementation Round 2 Security, Performance, and Documentation Review

## Result

**Unresolved actionable finding count: 0.**

Round 2 rechecked the remediated production source, focused tests, documentation, capability requirements, task state, and current evidence. All Round 1 security/performance/documentation findings are resolved, including the suspend/resume stale-generation race, phase-aware recovery routing, its production-path regression coverage, and the lease documentation contradiction. No new material issue was found.

## Resolved Round 1 Findings

### Suspend/resume stale-generation race — Resolved

Suspension rotates the retained intent generation, an explicitly reset campaign rotates it again, old delay/attempt results require the exact generation, and a tokenized lifecycle cleanup command prevents stale continuation publication (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:17-21`; `SDK/Sources/NearWire/NearWire.swift:1125-1129,1218-1255,1348-1411`). Tests cover resume during active-route cleanup, a held delay, and an in-flight recovery attempt with one retained intent and one successor (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1089-1227`).

### Phase-aware production routing — Resolved

`SDKLifecycleRecoveryFailure` binds the internal code to both its safe public error and authoritative phase disposition (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:78-116`). Direct admission/attachment/pump errors use it for recovery, and both direct-cleanup and with-lifetime gate `.terminal(code)` paths now preserve the recovery origin before error erasure (`SDK/Sources/NearWire/NearWire.swift:452-460,551-557,596-602,885-975`). `runScheduledRecovery` consumes that closed disposition rather than reclassifying it from public text or details (`SDK/Sources/NearWire/NearWire.swift:1237-1292`).

The all-code test proves the closed public-error/disposition pair for both phases, and a production-path recovery test drives a pre-active transport failure through the real gate/cleanup pipeline. With a two-attempt policy it proves exactly two claims/releases, cleared intent and Task, safe `secureConnectionFailed` status, and no third claim (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:900-933,1291-1319`). This test fails if gate-terminal recovery falls back to active-route/public-code retry behavior.

### Lease documentation contradiction — Resolved

The lease guide now states that either explicit connect or one generation-current recovery attempt may claim, and its bootstrap wording covers both paths (`Documentation/SDK-Connection-Lease.md:3-18`).

## New or Remaining Findings

None.

## Boundary and Evidence Recheck

- Pairing code remains in one actor-owned pending/active intent plus the reviewed one-shot admission transfer. It is absent from route owners, delay Tasks, status, errors, Events, diagnostics, logging, persistence, and Keychain. Defined failure, disconnect, exhaustion, and shutdown boundaries clear the intent (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:11-22`; `Documentation/SDK-Public-API.md:51-56`; `evidence/retention-resource-audit.md:1-11`).
- The recovery delay Task captures a weak actor plus token, generation, attempt, delay, and sleeper; it captures no pairing code. The actor owns at most one intent, one Task, one route slot, one shared receipt Task, and one Boolean deferred resume (`SDK/Sources/NearWire/NearWire.swift:1176-1216`; `evidence/retention-resource-audit.md:3-9`).
- Automatic recovery remains default-disabled, limited to 1...20 intent-wide attempts, and does not reset after brief route success. Exhaustion clears intent and work (`SDK/Sources/NearWire/NearWire.swift:1125-1195`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:845-882`).
- Replacement composes the reviewed mandatory-TLS pipeline, exposes no plaintext configuration, and does not requeue transport-accepted bytes. Pre-active TLS-like transport failure is permanent in the production recovery path (`Documentation/Transport-Security.md:5-48`; `evidence/requirement-to-evidence.md:12-15`).
- Public status errors are fixed, content-safe `NearWireError` values and discard pairing codes, endpoints, certificate data, raw transport/Security errors, remote text, wire bytes, Events, and application content (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:108-116`; `specs/sdk-connection-lifecycle/spec.md:105-124`).
- Added production source contains no UIKit/SwiftUI lifecycle observation, NotificationCenter, reachability monitor, background request, persistence, logging, analytics, external dependency, new target, product, or pod subspec. Package and pod manifests remain unchanged by this change.
- Current evidence covers route/lease chronology, retention/resources, mandatory TLS, no plaintext/replay, SwiftPM/CocoaPods public API parity, no observers/persistence/dependencies, and tool identity. Its validation summary explicitly requires fresh final runs after review remediation, and Tasks 6.1 through 6.4 remain open; these are correctly tracked completion gates, not unresolved implementation findings (`evidence/validation-gates.md:1-22`; `evidence/requirement-to-evidence.md:1-15`; `tasks.md:34-39`).

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-lifecycle-security-r2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-lifecycle-security-r2-swiftpm swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: PASS — 44 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS — `Change 'sdk-connection-lifecycle' is valid`.
- `git diff --check`: PASS.

## Final Verdict

**Ready to proceed to final validation from the security, performance/resource-bound, distribution, and documentation perspective.** Round 2 found zero unresolved actionable issues. Completion and archive still require the fresh full lifecycle, iOS Simulator, SwiftPM, CocoaPods, TLS, boundary, and evidence gates already tracked by Tasks 6 and 7.
