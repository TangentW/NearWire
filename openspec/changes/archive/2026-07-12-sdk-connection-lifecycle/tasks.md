## 1. Change Gate

- [x] 1.1 Validate proposal, design, delta specs, and tasks in strict mode before production or test source changes.
- [x] 1.2 Obtain independent pre-implementation architecture/API, correctness/testing, and security/performance/documentation reviews; record and resolve every actionable finding.

## 2. Supported Models and Observation

- [x] 2.1 Add the exact validated default-disabled `NearWireReconnectionPolicy` API, configuration integration, fixed safe fields/errors, checked capped delay calculation, and public boundary tests.
- [x] 2.2 Add `NearWireConnectionStatus`, current snapshot, latest-value bounded status hub, duplicate suppression, terminal shutdown behavior, and concurrency tests.
- [x] 2.3 Update SwiftPM and CocoaPods public consumer fixtures and API inventory gates for configuration, status, disconnect, suspend, and resume without exposing implementation types.

## 3. Lifecycle Ownership

- [x] 3.1 Implement one actor-owned pending/active intent capsule, promotion at connected commit, lifecycle generation, and data-minimized pairing-code retention/clearing across every pre-commit failure.
- [x] 3.2 Extend exact transition cancellation for manual disconnect and suspension without weakening Task-cancellation or shutdown precedence.
- [x] 3.3 Implement one exact-route constant-space cleanup receipt and idempotent async disconnect for pending attempts, active routes, recovery delays, repeated/cancelled callers, fail-closed noncompletion, release invocation, and stale callback isolation.
- [x] 3.4 Implement explicit suspension and nonblocking resumption, Boolean resume-during-cleanup intent, total command precedence, and no UIKit, NotificationCenter, reachability, or background-execution observer.

## 4. Bounded Recovery and Route Replacement

- [x] 4.1 Add exhaustive phase-aware terminal error/disposition mapping and tests that reject pre-active TLS-like transport failure, clock failure, permanent, lifecycle, hostile-input, ownership, and shutdown categories.
- [x] 4.2 Implement the single code-free weak-self recovery task, cancellation-completion handshake, deterministic capped delay, intent-wide attempt budget across brief success, generation checks, exhaustion, and safe status progress.
- [x] 4.3 Refactor the internal connection pipeline so recovery reuses reviewed admission composition while keeping initial thrown-result semantics and reconnecting state distinct.
- [x] 4.4 Prove every recovered route uses fresh lease, discovery, TLS, epoch, sequence, pump, and coordinator ownership with release-before-claim and no stale old-route mutation.
- [x] 4.5 Prove transport-accepted bytes are not requeued, offline pending Events remain eligible, and old-session reply affinity is dropped on replacement.

## 5. Tests and Documentation

- [x] 5.1 Add deterministic actor and barrier tests for the canonical command/status matrix, pending-intent clearing, receipt settlement independent of generation, disconnect, eligible resume, inert resume while connected/initial/recovering, terminal-versus-manual cancellation, held-delay cancellation, flapping success/exhaustion, and all stale winner orders.
- [x] 5.2 Add resource/retention tests for one intent capsule, one code-free delay Task, one shared cleanup receipt without actor waiter lists, no actor/task cycle, no code leakage, and no recurring work after terminal boundaries.
- [x] 5.3 Add package and CocoaPods integration coverage for the supported lifecycle API, retain production TLS public-connect gates, and combine them with deterministic fresh-route replacement tests proving no plaintext fallback or ambiguous replay.
- [x] 5.4 Update English SDK API, distribution, discovery, transport security, roadmap, README, and host lifecycle-integration documentation with exact guarantees and non-guarantees.

## 6. Validation and Evidence

- [x] 6.1 Run formatting, diff, source-boundary, API inventory, no-observer/no-dependency, version, and strict OpenSpec gates; save exact commands and results under `evidence`.
- [x] 6.2 Run focused lifecycle tests plus full Core and SDK suites under strict concurrency for macOS and iOS Simulator; save exact summaries and tool versions.
- [x] 6.3 Run complete SwiftPM and CocoaPods packaging gates, public consumer compilation, and integration suites; save logs and checksums.
- [x] 6.4 Record a requirement-to-test/evidence matrix, route/lease chronology audit, retention/resource audit, and spec-to-evidence completion audit.

## 7. Independent Completion Review

- [x] 7.1 Obtain independent architecture/API, correctness/testing, and security/performance/documentation implementation reviews and save each report.
- [x] 7.2 Fix every actionable finding, rerun affected validation, and obtain a fresh zero-finding review round across all three dimensions.
- [x] 7.3 Validate all OpenSpec specs strictly, archive `sdk-connection-lifecycle`, verify the archived evidence, and commit the isolated completed change before starting `sdk-ui`.
