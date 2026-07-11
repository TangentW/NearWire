## 1. Internal Lease Primitive

- [x] 1.1 Implement the two permanent selector literals, bounded ProcessInfo bootstrap, immutable Sendable private-monitor reference, retain-nonatomic monitor/owner associations, no mutable Swift global or unsafe isolation escape, and no configurable alternate production registry.
- [x] 1.2 Implement an opaque Sendable handle with exact-token, idempotent explicit and deinitialization release plus fixed redacted diagnostics.
- [x] 1.3 Implement stable safe contention and runtime-unavailable errors without public API, caller data, token data, or arbitrary underlying descriptions.

## 2. Deterministic Correctness and Concurrency Coverage

- [x] 2.1 Add sequential claim, contention, owner preservation, explicit release, reacquisition, repeated release, empty release, and deinitialization tests.
- [x] 2.2 Add a stale-handle ABA regression proving an old token cannot clear a newer owner.
- [x] 2.3 Add an external serial test-suite gate with initial/final claimability probes and defer/scope cleanup, then add start-gated concurrent claims, the retained-winner claim/release oracle, concurrent repeated release, and stale-release races without sleeps or reset APIs.
- [x] 2.4 Add Sendable, description, debug, interpolation, describing, reflecting, fixed-error, constant-retention, and no-caller-retention tests.

## 3. Boundaries and Documentation

- [x] 3.1 Prove NearWire construction and existing event, stream, and buffer APIs never touch the lease; prove current disconnected shutdown cannot release an unrelated owner while reserving exact-handle release for a future owning shutdown.
- [x] 3.2 Add a macOS validation harness that separately builds and dynamically loads two dylibs containing independent production lease copies and proves permanent selector, private-monitor, contention, exact/stale release, and reacquisition behavior; add isolated-fixture tests for bootstrap, claim, and release enter/exit failures without touching or resetting the process slot, including occupied-slot claim-exit error precedence and owner preservation.
- [x] 3.3 Keep every wrapper source, loader, generated dylib, and test runtime adapter outside SDK source and distribution globs; prove the production registry fixes its system adapter and process anchor, package product/target inventories are unchanged, production contains no dynamic loader, distributable binaries export no wrapper symbol, SwiftPM/CocoaPods remain equivalent, and implementation types and the runtime-operation seam remain non-public.
- [x] 3.4 Update English SDK architecture documentation and refine the roadmap into process-lease, session-admission, active-event-pump, public-connect, and connection-lifecycle changes.
- [x] 3.5 Confirm this change adds no pairing parsing, discovery run, TCP/TLS, Keychain, persistence, handshake, flow scheduling, task, timer, lifecycle observer, UI, or event transfer.

## 4. Validation, Review, and Archive

- [x] 4.1 Test and audit each bootstrap, claim, and release enter/exit outcome on isolated fixtures; runtime-unavailable precedence over contention; no slot access after failed enter; no association rollback after failed bootstrap exit; no handle after failed claim exit; release failure's lack of success/reacquisition guarantees; and exit-before-construction/cleanup. Then run focused tests, the multi-image harness, exported-symbol and distribution audits, full platform, packaging, boundary, structure, English, validation-tool, and OpenSpec gates.
- [x] 4.2 Capture exact commands, run identity, counts, expected notes, API inventory, and residual scope under the change evidence directory.
- [x] 4.3 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews and record every finding.
- [x] 4.4 Resolve every finding, add regressions, and repeat fresh multidimensional review rounds until all report zero unresolved findings.
- [x] 4.5 Complete the spec-to-evidence audit, mark every task complete, validate strictly, archive, and commit before session-admission apply begins.
