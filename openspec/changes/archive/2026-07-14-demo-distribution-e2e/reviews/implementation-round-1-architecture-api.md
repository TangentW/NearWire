# Implementation Round 1 Architecture and API Review

## Verdict

Changes required. No P0 or P1 findings were found. Two P2 findings remain actionable.

Unresolved finding count: **2**.

## Findings

### P2: Reset and terminal teardown do not own user-action Tasks

Confidence: 9/10.

`Demo/NearWireDemo/UI/DemoRootView.swift:31-35`, `77-79`, `91-93`, `106-108`,
`169-171`, and `176-178` create unstructured Tasks for Reset, sends, diagnostics, and Performance
actions without retaining their handles. `Demo/NearWireDemo/Application/DemoApplicationModel.swift:89-124`
cancels and joins only `eventTask` and `performanceTask`. The unowned operations mutate presentation
after suspension at `DemoApplicationModel.swift:65-82` and `126-134` without a lifecycle-generation
check.

A send, diagnostics refresh, or Performance start already queued by the UI can therefore resume after
Reset clears state and repopulate the presentation; a delayed Start action can also begin sampling after
Reset has completed its Stop step. Repeated taps can create an unbounded number of action Tasks. This
does not violate the one-Event-observer and one-Performance-observer count, but it violates the broader
bounded Task ownership and joined terminal-work intent recorded in
`openspec/changes/demo-distribution-e2e/design.md:28-30` and
`openspec/changes/demo-distribution-e2e/specs/demo-integration-application/spec.md:8-14`.

Recommended fix: move user actions into bounded model-owned Task slots, reject or serialize new actions
while Reset or teardown is active, cancel and join those slots before stopping the monitor or
disconnecting, and generation-check every post-await presentation mutation. Add focused evidence for a
delayed action crossing Reset; no SDK, Core, Viewer, or transport test double is needed.

### P2: Checked-in gates do not enforce the one-source-tree parity invariant

Confidence: 9/10.

The current project is correct: `Demo/NearWireDemo.xcodeproj/project.pbxproj:185-186` gives both App
targets the same five source file references, `project.pbxproj:178-179` gives both the same asset
catalog, and `project.pbxproj:199-202` defines `NEARWIRE_DEMO_SEPARATE_MODULES` only for the two SwiftPM
configurations. The condition is currently used only around optional imports in the four production
Swift files.

However, `Scripts/verify-structure.sh:109-119` checks only that a relative package reference exists and
that the condition appears twice in the project file. It does not compare the two targets' source and
resource memberships, prove the CocoaPods configurations omit the condition, or reject future use of
the condition outside import declarations. `Scripts/check-swift-boundaries.rb:141-145` validates the
Demo import allowlist but does not enforce those parity rules. The one-time hashes in
`openspec/changes/demo-distribution-e2e/evidence/validation-6.2-cocoapods-parity.md:9-27` prove the
current snapshot, but the normal bootstrap gate can pass after a later target-membership or conditional
behavior drift.

Recommended fix: extend the existing structure or boundary gate with a small deterministic check that
compares the two App targets' source and resource file-reference sets, verifies the SwiftPM-only
condition is absent from every CocoaPods configuration, and rejects `NEARWIRE_DEMO_SEPARATE_MODULES`
outside optional import guards. Keep this inside the existing validation entry points rather than
adding a new broad script framework.

## Confirmed Architecture and API Properties

- The SwiftPM and CocoaPods targets currently compile the same five production Swift files and the same
  asset catalog. Their only intended source-level difference is the optional module imports.
- Production Demo source imports only Foundation, SwiftUI, `NearWire`, `NearWireUI`, and
  `NearWirePerformance`; it imports no Core, transport, flow-control, Viewer, Network, Security, or SPI
  module.
- `DemoDriver` uses supported public facade operations: Event observation, send, causal reply, buffer
  diagnostics, Performance Start/Stop/state observation, disconnect, and shutdown. The exact incoming
  `NearWireEvent` remains local through `NearWire.reply`, preserving hidden instance and session
  affinity.
- `NearWireDemoApp` creates one `NearWire` instance and injects that exact instance into the one
  `NearWirePerformanceMonitor`, application model, and `NearWireConnectionView`. No singleton or second
  transport owner was introduced.
- The committed Podfile canonicalizes and validates its selected root, and CocoaPods validation remains
  isolated in a temporary root that preserves the Demo project's `..` local-package topology.
- Core, SDK, Viewer, and root-package dependency boundaries remain unchanged. The root package still
  has no third-party dependency, and the Demo adds no nested package manifest or podspec.
- The App Privacy Report amendment is honest. The unsigned archive and both products were inspected,
  the exact host permission denial and absent command-line tools are recorded in
  `evidence/validation-6.3-products-privacy.md:36-51`, no report is claimed, and Organizer export remains
  a mandatory signed-archive `release-hardening` gate in
  `evidence/validation-6.5-environment-and-exclusions.md:36-46`.

## Validation Performed

- Read the complete active proposal, design, delta specs, tasks, artifact reviews, implementation
  evidence, Demo production and test source, Xcode project and schemes, Podfile, workspace, validation
  scripts, and Demo/root documentation.
- Inspected the complete tracked diff and every untracked active-change file.
- `env DO_NOT_TRACK=1 openspec validate demo-distribution-e2e --strict --no-interactive`: passed.
- `ruby Scripts/check-swift-boundaries.rb`: passed.
- `bash Scripts/verify-structure.sh`: passed.
- `bash Scripts/verify-version.sh`: passed for `0.1.0`.
- `swift format lint --strict --recursive Demo`: passed.
- `git diff --check`: passed.
- Current SwiftPM `NearWireDemo` generic iOS Simulator build: passed with signing disabled.
- Confirmed the temporary CocoaPods root's production source tree and Podfile match the working tree;
  current `NearWireDemoCocoaPods` generic iOS Simulator build from that workspace passed with signing
  disabled.
- Xcode project inventory resolved all four maintained targets and both shared Demo schemes.
- Parsed target membership with CocoaPods' Xcodeproj library and independently confirmed identical
  production source/resource sets and SwiftPM-only compilation conditions.
- Inspected both newly built App products: bundle identifiers, iOS 16 minimum, `_nearwire._tcp` host
  declaration, and both privacy manifests were correct; all four embedded manifests were byte-identical
  to their owning SDK source manifests.

The reviewer modified no production or test source. This report is the only review write.
