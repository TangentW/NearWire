# Spec-to-Evidence Audit

Date: 2026-07-14
Change: `demo-distribution-e2e`

## Audit result

Every requirement and scenario in the three delta specifications has corresponding implementation
and recorded evidence. Tasks 1.1 through 7.2 are complete. Fresh architecture/API,
correctness/testing, and security/performance/documentation round-2 reviews report zero unresolved
material or actionable findings under the product owner's reference-Demo acceptance boundary.

This audit claims a maintained reference application that builds and runs through SwiftPM and
CocoaPods and accurately demonstrates the supported public APIs. It does not claim configured
signing, a signed-product entitlement inspection, stable-signer continuity, real-device permission
behavior, or an exported Xcode App Privacy Report. Those remain mandatory final
`release-hardening` gates.

## Requirement audit

| Capability and requirement | Implementation and validation evidence | Result |
| --- | --- | --- |
| `demo-integration-application`: one explicit SDK and Performance lifecycle | `NearWireDemoApp.swift`, `DemoApplicationModel.swift`, `DemoDriver.swift`; runtime, launch, production-regression, and complete-gate evidence | Covered |
| `demo-integration-application`: bounded ordinary and latest-value Events | `DemoModels.swift`, `DemoDriver.swift`, `DemoRootView.swift`; compact boundary tests and runtime evidence | Covered |
| `demo-integration-application`: bounded Viewer controls and causal replies | `DemoControlEvaluator`, sequential Event observation, and `NearWire.reply`; compact mapping tests plus causal-route regressions | Covered |
| `demo-integration-application`: explicit optional Performance action | injected `NearWirePerformanceMonitor`, explicit Start/Stop UI, state observation; runtime and launch evidence | Covered |
| `demo-integration-application`: required host declarations without extra privilege | shared `Info.plist` and entitlement-free App targets; both built products inspected | Covered |
| `demo-integration-application`: public-boundary validation | three compact logic tests, one launch smoke, SwiftPM/CocoaPods builds, and focused SDK/Viewer regressions | Covered |
| `demo-integration-application`: internal developer runbook | `Demo/README.md` and root README link; documentation review approved | Covered |
| `repository-structure`: Demo completes root workspace | manual Demo project, relative workspace reference, shared source tree, no nested manifest/podspec/generated Pods state; structure and workspace builds passed | Covered |
| `sdk-distribution`: SwiftPM and CocoaPods application parity | both App targets compile the same five production sources and asset; exact source/resource/public-call-site hashes and successful builds recorded | Covered |
| `sdk-distribution`: complete built-product privacy inputs | both products and unsigned archive inspected; four embedded manifests are valid and byte-identical to source; unavailable Organizer export is honestly recorded | Covered with named final release exclusion |
| `sdk-distribution`: coherent release metadata | Demo, Viewer, podspec, compiled SDK, and root version checks passed; relative and machine-independent project metadata inspected | Covered |

All named scenarios are covered by the implementation anchors above and the following primary
records:

- `apply-2.2-2.4-distribution-foundation.md`
- `apply-3.1-3.6-demo-runtime.md`
- `apply-4.1-4.3-ui-documentation.md`
- `validation-5.1-5.2-demo-tests.md`
- `validation-5.3-production-regressions.md`
- `validation-6.1-spm-build-launch-archive.md`
- `validation-6.2-cocoapods-parity.md`
- `validation-6.3-products-privacy.md`
- `validation-6.4-complete-gates.md`
- `validation-6.5-environment-and-exclusions.md`

## Validation audit

- SwiftPM Demo Simulator build, build-for-testing, three compact unit tests, and one launch UI test:
  passed.
- Interactive Simulator launch through the iOS harness: stable initial surface confirmed.
- Unsigned generic iOS archive: passed; both SwiftPM privacy-resource bundles embedded.
- CocoaPods 1.16.2 temporary-root install and warnings-as-errors Simulator build: passed; identical
  source, resource, and public-call-site hashes recorded; repository remained free of generated Pod
  state.
- Focused SDK causal-reply/route-affinity/production-TLS and Viewer bidirectional flow regressions:
  passed.
- Complete applicable Viewer suite: 394 passed, zero failed, two documented opt-in skips; only the
  user-deferred configured-signing assertion was excluded.
- Complete bootstrap: passed, including 536 root Simulator package tests with four documented
  existing skips, 214 Core harness tests, real TLS tests, podspec private lint, and repository gates.
- Swift formatting, plist/project/workspace/scheme lint, English, structure, package, privacy,
  boundary, version, `git diff --check`, and strict active-change OpenSpec validation: passed.

Exact commands, result counts, product paths, archive identity, environment versions, and exclusions
are preserved in the named validation records rather than duplicated here.

## Review audit

Round 1 found no P0 or P1 issue. Its two architecture P2 observations are recorded in
`implementation-review-disposition.md` as accepted non-blocking residual risks under the explicit
reference-Demo boundary. No code, test, or validation-script expansion was warranted. Both other
round-1 dimensions approved with zero material findings.

Fresh round 2 independently approved all three required dimensions with zero unresolved material or
actionable findings:

- `reviews/implementation-round-2-architecture-api.md`
- `reviews/implementation-round-2-correctness-testing.md`
- `reviews/implementation-round-2-security-performance-documentation.md`

## Archive gate

The change may be archived after this audit is independently checked for material omissions, strict
OpenSpec validation passes again, and the archive synchronizes all three delta specifications into
the canonical spec set. Task 7.3 is complete only after archived evidence, canonical specs, final
repository checks, and commit contents are verified.
