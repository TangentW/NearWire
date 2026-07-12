# SDK Connection Lifecycle Implementation Round 3 Security, Performance, and Documentation Review

## Result

**Unresolved actionable finding count: 0.**

Round 3 reviewed the latest coordinator cleanup-start marker remediation, production lifecycle source, focused tests, documentation, normative requirements, and current evidence. It also rechecked all prior pairing-code, bounded-work, Task/receipt ownership, TLS/no-replay, safe-error, observer/persistence/dependency, distribution, and documentation dimensions. No material security, performance/resource-bound, distribution, or documentation issue remains.

## Cleanup-Start Marker Review

### Ownership and retention are constant-space and content-free

The terminal coordinator still owns one waiter Task and one exact lease. Its new `cleanupStarted` callback runs only after successful terminal observation and before release; terminal-wait failure vaults the lease and returns without installing a marker (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:188-271`).

Production supplies two `@Sendable` closures that capture only the exact route token, the existing cleanup receipt, and a weak actor reference. They capture no pairing code, endpoint, Viewer/App metadata, Event, channel, route, owner, or strong actor (`SDK/Sources/NearWire/NearWire.swift:505-524`). The coordinator's existing Task/self lifetime is broken by `clearTask()` on normal delivery and wait failure; the callbacks add no actor/coordinator cycle.

The actor marker is one optional `(token, receipt)` tuple. It references the same per-route receipt already owned by the current slot rather than creating a second receipt, waiter, continuation array, Task, timer, or poll (`SDK/Sources/NearWire/NearWire.swift:129-138,1047-1061`). Exact terminal delivery settles the receipt and clears only the matching marker before tokenized state/recovery handling; shutdown also clears it (`SDK/Sources/NearWire/NearWire.swift:1063-1102,1456-1476`). At most one route/coordinator can exist, so repeated or stale cleanup callbacks cannot accumulate markers.

### TLS and lease chronology remains fail-closed

The resulting chronology is:

1. mandatory-TLS route produces terminal evidence;
2. the coordinator installs the content-free exact cleanup marker;
3. the exact lease release invocation occurs;
4. terminal delivery settles the same receipt and clears the marker;
5. only generation-current actor logic may schedule a fresh discovery/TLS/lease claim.

No successor claim can start while the current slot, lifecycle cleanup command, recovery Task, or spontaneous cleanup marker exists. The marker therefore closes the command/preflight race without transferring, resetting, or prematurely releasing ownership (`SDK/Sources/NearWire/NearWire.swift:205-218,1047-1102`; `specs/sdk-process-connection-lease/spec.md:3-22`). A failed terminal wait still creates no marker or delivery and keeps the lease permanently fail-closed.

The new opposing-order tests hold release while disconnect/suspend commands overlap and prove that terminal cleanup cannot regress the latest suspension status. Both share one release path and finish with the last actor command's coherent status (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1326-1409`).

## Prior Boundary Recheck

- Pairing code remains in one actor-owned pending/active intent plus the reviewed one-shot admission transfer. Delay Tasks, callbacks, coordinator, marker, receipt, status, errors, Events, diagnostics, logs, persistence, and Keychain contain no code (`SDK/Sources/NearWire/Connection/SDKConnectionLifecycle.swift:11-22`; `Documentation/SDK-Public-API.md:51-56`).
- Recovery remains default-disabled, limited to 1...20 intent-wide attempts, and does not reset after brief success. Generation checks, Task tokens, the one cleanup-command token, one marker, and exact receipts prevent stale or concurrent work from authorizing another route.
- Phase-aware recovery maps direct failures and transition-gate terminal codes before public error erasure. The production pre-active transport-failure test proves permanent failure, safe error, exact release, cleared intent/Task, and no third claim under a two-attempt policy (`SDK/Sources/NearWire/NearWire.swift:885-975,1237-1292`; `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:1296-1324`).
- Every replacement continues through fresh Bonjour discovery, mandatory TLS 1.3/ALPN evaluation, hello/admission, epoch, sequence state, pump, coordinator, and lease. No plaintext option or accepted-byte requeue was introduced (`Documentation/Transport-Security.md:5-48`; `evidence/requirement-to-evidence.md:12-15`).
- Public lifecycle errors and status remain fixed and content-safe. No pairing code, endpoint/interface, certificate/fingerprint, raw transport/Security error, remote text, wire bytes, Event, or application content is exposed.
- The production diff adds no UIKit/SwiftUI lifecycle observer, NotificationCenter, reachability monitor, background execution request, persistence, logging, analytics, external dependency, product, target, pod subspec, entitlement, or privacy declaration. Root package and pod dependency boundaries remain unchanged.
- SwiftPM and CocoaPods expose the same lifecycle API in Swift 5 language mode. Existing evidence records package/pod consumer compilation, mandatory TLS gates, boundary checks, and tool identity (`evidence/validation-gates.md:1-22`; `evidence/run-identity.md:1-12`).

## Evidence Status

The existing retention and route-chronology audits remain factually correct: one route owns one receipt/shared Task and one coordinator/lease; release precedes delivery and fresh claim (`evidence/retention-resource-audit.md:1-11`; `evidence/route-lease-chronology-audit.md:1-17`). The final Task 6 evidence refresh should explicitly record the new content-free cleanup-start marker and update focused/full counts after remediation. Those gates remain open and are correctly described as required before completion rather than already-final evidence (`tasks.md:34-39`; `evidence/validation-gates.md:14,22`).

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-lifecycle-security-r3-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-lifecycle-security-r3-swiftpm swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKPublicConnectionOrchestrationTests`: PASS — 46 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS — `Change 'sdk-connection-lifecycle' is valid`.
- `git diff --check`: PASS.

## Final Verdict

**Ready to proceed to final validation from the security, performance/resource-bound, distribution, and documentation perspective.** Round 3 found zero unresolved actionable issues. Completion and archive still require the fresh full lifecycle, iOS Simulator, SwiftPM, CocoaPods, TLS, boundary, and evidence gates tracked by Tasks 6 and 7.
