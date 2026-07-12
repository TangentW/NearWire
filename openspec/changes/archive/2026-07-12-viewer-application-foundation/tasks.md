## 1. Change Gate

- [x] 1.1 Complete and strictly validate the proposal, design, Viewer capability spec, repository-structure delta, and task plan before modifying production or test source.
- [x] 1.2 Obtain lightweight independent architecture/API, correctness/testing, and security/performance/documentation reviews of the artifacts and resolve actionable findings.

## 2. Manual Viewer Project and Window Runtime

- [x] 2.1 Create the manual `Viewer/NearWireViewer.xcodeproj`, app/test targets, macOS 13 and Swift 5 settings, local `NearWireCore` product reference, App Sandbox server-only entitlements, local-network/Bonjour Info.plist values, Viewer privacy manifest, stable automatic Apple Development signing configuration with explicit ad-hoc test override, and root workspace reference without changing root package or pod manifests.
- [x] 2.2 Implement the single-window SwiftUI app, `@MainActor` application model, exact generation state, automatic production appearance start, XCTest-host isolation, one idempotent one-second cleanup receipt, last-window termination, and closed safe presentation errors.
- [x] 2.3 Implement the focused pairing/listener/pending-approval UI, accessibility, clipboard action, truthful TLS and nearby-discovery wording, approval preference, pause/resume, retry, TLS-only reset, confirmed full identity reset, and future-workspace placeholder.

## 3. Persistent Identity and Pairing

- [x] 3.1 Implement stable-signer macOS login-Keychain storage with non-interactive exact generic-password accounts, TLS metadata/persistent certificate reference, exact nonextractable key tag, foreign-item preservation, stable installation ID, one stop-before-repair attempt, TLS-only reset, confirmed full reset, and partial-delete/recreation failure behavior.
- [x] 3.2 Implement the fixed-profile Security-backed P-256/SHA-256 self-signed X.509 v3 builder, bounded positive serial, canonical UTC/Generalized time encoding, exact validity/extensions, profile/signature/time/trust/key-correspondence validation, near-expiry renewal, `SecIdentity` lookup, and Core transport adaptation.
- [x] 3.3 Implement the unbiased `SecRandomCopyBytes` pairing generator, exact Core validation/service-name mapping, memory-only lifecycle, and installation-ID-derived `vid` TXT record.

## 4. Secure Bonjour Listener and Admission

- [x] 4.1 Extend the internal secure Viewer listener with one validated advertisement input and safe service-registration events while retaining mandatory TLS, peer-to-peer routing, raw Network type hiding, and cancellation/claim atomicity.
- [x] 4.2 Implement tokenized Viewer listener startup, ready-plus-registration commit, bounded collision retry, ordinary refresh with existing-handoff preservation, pause, failure recovery, and stale callback rejection.
- [x] 4.3 Implement synchronous bounded generation ingress, latest-only pending UI coalescing, one permanent admission connection core per claimed wrapper, weak immutable callback routing, Viewer-Hello admission at TLS ready, continuous bounded decode through one App Hello, safe negotiation summary, same-owner opaque handoff, one 32-slot runtime-wide pre-claim-through-cleanup owner budget, one 10-second claim-through-decision deadline, automatic/confirmation policy, the specified transition table, exact terminal/cleanup-complete slot-release gates, and placeholder same-core cleanup.

## 5. Tests, Documentation, and Packaging Evidence

- [x] 5.1 Add deterministic unit and integration tests for DER/profile/signature/validity boundaries, real Security trust parsing, injected identity-state transitions, real login-Keychain lifecycle, the conditional stable-signer update-reuse and unrelated-signer gate, foreign-item preservation, nonexportable signing key, installation/TLS reuse, renewal, partial delete, both reset scopes, random-source failure/rejection sampling, pairing lifecycle, listener generation races, registration mismatch/retry, silent/partial peers in both policies, exact 32/33 combined owner boundary, one non-resetting 10-second decision deadline, cleanup-complete slot release, Viewer-Hello once, continuous-owner/coalesced-input ordering, policy snapshot, pause, replacement commit/failure, stale callbacks, and bounded shutdown cleanup.
- [x] 5.2 Add Core transport tests for advertisement validation, service event mapping, mandatory TLS/P2P preservation, and cancel-versus-claim; add Viewer privacy/Info.plist/entitlement parsing, local-network failure, presentation, and SwiftUI composition smoke tests without brittle pixel assertions.
- [x] 5.3 Add English Viewer architecture/operator documentation and update README, roadmap, workspace/project ownership, certificate renewal/reset, Bonjour visibility, local-network privacy, sandbox, admission limits, continuous-owner handoff, and explicit next-change boundaries.
- [x] 5.4 Build, ad-hoc-test-sign, and test the Viewer scheme plus all existing Core/SDK suites; inspect final plist, entitlements, privacy resource, and local package linkage; run format, English, diff, structure, boundaries, package, podspec, strict OpenSpec, and workspace gates; save exact commands and results under the active change evidence directory. Preserve the supported-signer A/unrelated/B execution as a mandatory deferred `release-hardening` gate when the current host has no valid identities.

## 6. Independent Completion Review

- [x] 6.1 Obtain independent architecture/API, correctness/testing, and security/performance/documentation implementation reviews and save each report.
- [x] 6.2 Fix every actionable finding, rerun affected validation, and repeat all three review dimensions until a fresh round reports zero unresolved findings.
- [x] 6.3 Complete the requirement-to-evidence audit, archive `viewer-application-foundation`, and verify archived specs and evidence before starting `viewer-multidevice-flow-control`.
