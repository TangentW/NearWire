## 1. Change Gate

- [x] 1.1 Complete and strictly validate the proposal, design, Demo capability, repository-structure delta, SDK-distribution delta, and task plan before modifying production or test source.
- [x] 1.2 Obtain lightweight independent architecture/API, correctness/testing, and security/performance/documentation artifact reviews; fix every actionable finding and strictly revalidate before apply.

## 2. Manual Project and Distribution Foundations

- [x] 2.1 Create the manually maintained `Demo/NearWireDemo.xcodeproj` with iOS 16 and Swift 5 settings, one SwiftPM App target linked to local `NearWire`, `NearWireUI`, and `NearWirePerformance`, one small unit-test target, one UI launch-smoke target, shared schemes, and no machine-specific signing values or generator.
- [x] 2.2 Add the Demo project to root `NearWire.xcworkspace` with a relative reference and prove Viewer and the SwiftPM Demo resolve and build independently without CocoaPods or project generation.
- [x] 2.3 Add one CocoaPods consumer target and root-relative `Demo/Podfile` for `NearWire/UI` plus `NearWire/Performance`; use an import-only `NEARWIRE_DEMO_SEPARATE_MODULES` condition solely on the SwiftPM target, validate the canonical Pod root, keep business/resource membership identical, and commit no generated Pods workspace, lockfile, or build output.
- [x] 2.4 Add shared host Info.plist, asset, bundle/version, local-network, Bonjour, deployment, language, warnings, and entitlement settings for both targets; extend version and project/source-membership checks, including Viewer and every Demo configuration, without a new broad script framework.

## 3. Shared Demo Runtime and Event Behavior

- [x] 3.1 Add internal Sendable Codable Demo message, counter, banner-control, result, summary, validation, and fixed Event-type models with exact 512-byte input and 50-summary bounds.
- [x] 3.2 Add one small Demo-owned production driver that composes only public `NearWire` and `NearWirePerformance` operations, keeps each exact source Event local through causal reply, and exposes no registry or generic mock transport.
- [x] 3.3 Add one MainActor application model with at most one Event and one Performance-state observation Task, idempotent activation, explicit Reset-only stream restart, generation invalidation, exact cancellation/join ordering, reusable disconnect versus terminal shutdown semantics, stale-result rejection, content-safe errors, and no automatic connect, sampling, retry, lifecycle inference, or persistence.
- [x] 3.4 Implement normal `demo.message`, keep-latest `demo.counter`, public send-result and buffer-diagnostics presentation with precise local-only language and no remote-delivery claim.
- [x] 3.5 Implement bounded Viewer control observation, exact type/direction/size validation, banner replacement, causal `demo.control.result` reply, unknown/invalid no-op handling, overflow recovery guidance, and newest-50 presentation.
- [x] 3.6 Implement explicit Performance Start/Stop and state observation, safe failure presentation, reset/teardown ordering, and no duplicate collector, timer, queue, retry, or transport.

## 4. Native Demo UI and Documentation

- [x] 4.1 Build the SwiftUI App root and one adaptive Demo surface containing the injected NearWire connection panel, Event lab, current banner/control history, local queue diagnostics, and Performance controls.
- [x] 4.2 Add deterministic English labels, accessibility identifiers/hints, bounded text input, non-color status, keyboard-safe layout, destructive-action confirmation where needed, and no clipboard/log/share/persistence surface for Event content or pairing data outside the SDK-owned connection UI.
- [x] 4.3 Replace the placeholder Demo README and add English integration documentation for both package-manager builds, pairing, Events, controls/replies, Performance, diagnostics, privacy declarations, cleanup, local-only semantics, and final signing exclusions.

## 5. Unit, Integration, and Launch Coverage

- [x] 5.1 Add one compact Demo unit suite for the 512-byte input boundary, valid/invalid banner-control mapping, and 49/50/51 summary retention; do not duplicate SDK queue, lifecycle, transport, TLS, or concurrency tests.
- [x] 5.2 Add a minimal UI launch test for the maintained SwiftPM App surface, connection field, Event controls, Performance controls, accessibility identifiers, and initial inert state.
- [x] 5.3 Run the existing focused SDK/Viewer bidirectional exchange and route-affinity regressions alongside the compact Demo tests; prove no Demo test transport or alternate protocol owner was introduced.

## 6. Distribution, Privacy, and Complete Validation

- [x] 6.1 Build/test/launch the SwiftPM Demo on an iOS Simulator and create an unsigned generic iOS archive; build the root workspace Viewer scheme and run affected root package regressions.
- [x] 6.2 Create a temporary root-layout snapshot preserving Demo's `..` local-package reference and required package/pod inputs, canonicalize and verify its Pod root, install with CocoaPods 1.16 or later, build `NearWireDemoCocoaPods` for an iOS Simulator with warnings as errors, compare source/resource/public-call-site hashes, and prove the original repository is unchanged afterward.
- [x] 6.3 Inspect both real App products for exact Info.plist, entitlement absence, base SDK and Performance privacy bundles/manifests, module/dependency boundaries, bundle/version settings, and forbidden absolute/generated state; attempt Xcode's App Privacy Report export from the unsigned archive, save it when host UI automation is available, or record denied UI access and the absence of a CLI exporter without claiming report completion.
- [x] 6.4 Run complete Demo, Viewer, and root package suites plus Swift formatting, plist, English, structure, package, podspec, boundary, version, staged-diff, and strict OpenSpec gates; save exact commands and results under this change's evidence directory.
- [x] 6.5 Record the installed Xcode/CocoaPods identity, Simulator/runtime identity, deterministic test/resource counts, built-product paths, unsigned archive and report-attempt identity, known environment limitations, and the mandatory configured-signing and privacy-report work left to `release-hardening`.

## 7. Independent Completion Review

- [x] 7.1 Obtain independent architecture/API, correctness/testing, and security/performance/documentation implementation reviews and save every report.
- [x] 7.2 Fix every actionable finding, rerun affected and complete validation, and repeat all three review dimensions until a fresh round reports zero unresolved findings.
- [x] 7.3 Complete a requirement-to-evidence audit, archive `demo-distribution-e2e`, verify canonical specs and archived evidence, and commit the completed change before starting `release-hardening`.
