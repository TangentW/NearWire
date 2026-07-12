# Viewer Foundation Requirement-to-Evidence Audit

Date: 2026-07-12

## Audit Basis

This audit covers every requirement and scenario in both change deltas:

- `specs/viewer-application-foundation/spec.md`
- `specs/repository-structure/spec.md`

The exact validation commands and environment are recorded in `implementation-validation.md`. Round 1 and Round 2 finding resolution is recorded in the corresponding remediation reports.

## Requirement Matrix

| Requirement | Implementation evidence | Behavioral and packaging evidence | Result |
| --- | --- | --- | --- |
| Native single-window macOS application | `Viewer/NearWireViewer.xcodeproj`, `Viewer/NearWireViewer/App/NearWireViewerApp.swift`, and `ViewerApplicationModel.swift` provide one SwiftUI `Window`, remove New Window, start one production runtime on appearance, and coordinate last-window termination through an idempotent one-second cleanup receipt. | Final Viewer XCTest covers start-once, stop, delayed cleanup completion/timeout, reset ordering, stale callbacks, and view composition. Release build settings prove macOS 13 and Swift 5 mode. | Proven |
| Separate persistent installation and TLS identities | `ViewerIdentityStore.swift` uses exact standard-login-Keychain selectors, non-interactive `LAContext` operations, a permanent and sensitive creation request, exact P-256/nonexportable reload validation, metadata-owned certificate reference, full cryptographic ownership validation, one bounded repair, and distinct reset scopes. `ViewerCertificateBuilder.swift` provides the fixed profile, canonical UTC/Generalized time, signature, trust, key matching, validity, and renewal checks. The project now requires stable automatic Apple Development signing for maintained builds. | Same-binary real Keychain and injected lifecycle coverage passes. The conditional three-product XCTest gate binds phase data into signed Info.plist fields, records distinct signed bundle versions, Code Directory hashes, product paths, build identifiers, and signer fingerprints, requires post-denial completion, covers exact unrelated-signer read/use/reset/delete denial, and documents reproducible fail-fast commands. The user explicitly deferred execution on a configured signing host to mandatory `release-hardening` final verification. | Implemented; final release evidence deferred |
| Exact ephemeral pairing and Bonjour publication | `ViewerPairingCodeGenerator.swift` uses bounded rejection sampling over the canonical alphabet. `ViewerApplicationModel.swift` publishes only after ready plus exact registration, retries collision three times, and commits replacement before cancelling old publication. | Pairing-source, lifecycle, collision, service-removal, replacement-success/failure, clipboard-state, and advertisement tests pass. Core TXT validation proves only canonical `vid`. | Proven |
| Secure listener keeps Bonjour and raw transport internal | Core adds only repository SPI `SecureViewerServiceAdvertisement`, safe registration events, typed local-network failure, and one-shot `reject`; raw `NWListener` and `NWConnection` remain hidden. | Focused secure transport run: 16 passed, 0 failed, 0 skipped, including production TLS 1.3/ALPN, P2P parameters, advertisement mapping, typed permission mapping, and cancel-versus-claim atomicity. Existing boundary gates pass. | Proven |
| Default-automatic, optional, bounded new-App admission | `ViewerAdmission.swift` synchronously gates listener ingress and channel events, installs attempts plus cleanup ownership before claim, retains one of 32 combined owner slots until cleanup completion, releases the exact slot before completing the handle/stop receipt, uses one injected monotonic 10-second decision deadline, retains one continuous core/decoder, samples approval policy, and atomically coordinates same-core handoff with shutdown. Pending UI snapshots are latest-only, fair across MainActor turns, and runtime-generation scoped. | Full Viewer XCTest passes delayed cancellation, placeholder ownership, the 32/33 bound, deterministic receipt ordering, and partial drain/refill in one runtime alongside the existing race, backpressure, deadline, and handoff coverage. Fresh architecture/API, correctness/testing, and security/performance/documentation reviews report zero unresolved implementation findings. | Proven |
| Truthful recovery-oriented foundation UI | `ViewerRootView.swift` exposes pairing status/actions, pause, approval, bounded pending summaries, fixed recovery, future-workspace placeholder, and the exact unauthenticated-TLS and nearby-visible-identifier wording. `ViewerPresentationModels.swift` is a closed diagnostic model. | Presentation and SwiftUI composition tests pass. English validation passes. No raw transport, Security, pairing, certificate, endpoint, or App content is rendered through error paths. | Proven |
| Application metadata and privacy match local discovery | Source resources contain only App Sandbox plus network-server entitlement, exact `_nearwire._tcp` and local-network wording, the Viewer Device ID declaration, and the app-local UserDefaults reason `CA92.1`. | Final ad-hoc Release product passes strict code-sign verification. Built entitlements contain exactly sandbox and network server; built Info.plist, privacy manifest, and dynamic linkage were inspected. No plaintext fallback, unused Required Reason category, or third-party runtime is present. | Proven |
| Viewer project is committed incrementally | Root workspace references `Viewer/NearWireViewer.xcodeproj` by relative path. The manual project owns Viewer app/test source and references the root package locally. | Structure and dependency gates prove exactly one root `Package.swift` and podspec, no project generator, no Viewer dependency in root manifests, and no Demo placeholder. Workspace listing and Release build pass. | Proven |

## Cross-Cutting Gates

- Full strict-concurrency Swift package regression: 522 executed, 0 failed; 7 environment-dependent Security/Network cases skipped on the current run.
- Existing comprehensive repository gate: final rerun passed every OpenSpec, structure, language, version, module-boundary, SwiftPM, CocoaPods, iOS simulator, isolated Core, and real TLS integration check.
- Latest complete Viewer XCTest: 55 passed, 1 explicit stable-signer update-boundary skip, 0 failed.
- Final formatting lint, strict OpenSpec validation, plist validation, and `git diff --check`: passed.
- No new validation script was introduced; behavior uses XCTest and packaging uses the repository's existing gate.
- Final implementation reviews: Round 7 architecture/API, Round 6 correctness/testing, and Round 6 security/performance/documentation each report 0 unresolved actionable findings.
- Deferred final-system gate: execute the documented supported-signer A/unrelated/B Keychain sequence during `release-hardening`; NearWire completion remains prohibited until it passes.

## Residual Scope

This change deliberately closes accepted handoffs with a placeholder consumer. Active multi-device sessions, flow policy, Event transfer, persistence/search/export, event explorer/control UI, and performance dashboards remain absent and are assigned to the next four Viewer changes. No evidence in this audit claims those later capabilities.
