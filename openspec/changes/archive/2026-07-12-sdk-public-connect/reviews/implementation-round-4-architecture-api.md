# Post-Implementation Architecture and API Review — Round 4

## Scope Reviewed

I reviewed the current `sdk-public-connect` worktree against the proposal, design, normative capability specifications, completed task plan, evidence set, `NearWire-Platform-Architecture.md`, all prior architecture/API review findings, public API inventory, package manifests, and focused connection tests. This was a report-only review; no production, test, specification, evidence, or documentation source was modified.

## Prior-Finding Verification

The Round 3 lock-discipline finding is resolved.

- `requestCancellationResult` now captures `deliveredCancellationToTarget` into immutable `deliveredAtLinearization` while holding the transition-gate lock and returns only that local after unlocking and invoking the target (`SDK/Sources/NearWire/Connection/SDKSessionTransitionGate.swift:120-143`). No protected cancellation-delivery state is read outside the lock.
- The result has coherent linearization semantics: a request with no current target reports false; a target installed after that point is cancelled by installation; a later request reports the delivery remembered for the cancellation epoch (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:73-99`).
- Repeated requests do not redeliver a target, and both public/nested admission-handler orders invoke the admission owner and discovery cancellation exactly once (`SDKPublicConnectionOrchestrationTests.swift:23-70`; `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:4149-4200`). This satisfies the shared-authority and one-request-per-owner requirements.

The earlier identity-start, production lease release, target-generation, lifetime handoff, weak-owner, pairing-retention, and terminal-coordinator remediations remain intact.

## Architecture and API Assessment

No actionable architecture or API issue remains.

- **Repository placement:** platform-neutral Event-record and frame-size calculations remain in `Core`; iOS Keychain, process ownership, Bonjour/TLS admission composition, public orchestration, and active-owner lifecycle remain in `SDK`.
- **Public boundary:** the supported addition remains the instance-actor `connect(code:)` plus fixed error cases and existing state values. No transition gate, lease, Keychain, Network, Security, admission, pump, wire, endpoint, certificate, or internal limit type enters a supported signature.
- **Ownership and concurrency:** one actor slot, one shared transition gate, one session lifetime, and one terminal coordinator define the connection. Cancellation/terminal chronology and target replacement are lock-linearized; the process handle and target cells are one-shot; core-to-`NearWire` operations are weak; the coordinator callback is weak and tokenized; and failed terminal observation remains fail-closed.
- **Packaging:** the root SwiftPM and CocoaPods definitions retain the same products and targets, link only Apple's `Security.framework` on the SDK target, and add no third-party SDK runtime dependency.
- **Scope:** disconnect, reconnect, lifecycle policy, terminal-error observation, background behavior, UI, and performance collection remain outside this change.
- **Plan sufficiency:** the narrowed task 3.7 still requires both-winner cancellation/target and terminal/commit coverage, public async result barriers, stale-callback and one-wait/release audit, and supported retry outcomes. Together with tasks 3.2, 3.4, 3.5, 3.8, 3.9, and 3.10 and the recorded evidence, it remains sufficient for every normative cancellation, ownership, retention, and cleanup requirement without broadening lifecycle scope.

## Validation

- `swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnection` passed: 38 tests, 0 failures.
- `./Scripts/verify-boundaries.sh` passed all Swift module, SPI, secure-construction, SwiftPM, CocoaPods, and distribution-manifest boundary checks.
- `git diff --check` passed.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive` passed.

## Review Result

**Unresolved actionable findings: 0.** Round 4 architecture/API review is clean.
