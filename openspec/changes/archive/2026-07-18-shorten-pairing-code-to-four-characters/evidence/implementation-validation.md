# Implementation Validation

Date: 2026-07-19

## Specification

- `openspec validate shorten-pairing-code-to-four-characters --strict`
  - Exit code: `0`
  - Result: change is valid.

## Swift Package

- `swift test --filter PairingDiscoveryIdentityTests`
  - Exit code: `0`
  - Result: 7 tests executed, 0 failures.
- `swift test --filter SDKPublicConnectionFoundationTests/testInvalidPairingCodeErrorDescribesTheFourCharacterContract`
  - Exit code: `0`
  - Result: 1 test executed, 0 failures.
- `swift test`
  - Exit code: `0`
  - Result: 556 tests executed, 0 failures, 0 unexpected failures.
- `swift build -c release`
  - Exit code: `0`
  - Result: release build completed successfully.

The first attempt to rerun the focused SDK test inside the restricted filesystem failed before
manifest evaluation because Swift could not write its normal Clang module cache. The unchanged
command was rerun with the normal compiler-cache permission and passed. This was an execution
environment limitation, not a source or test failure.

## Viewer

- Focused Viewer test selection:
  - `testPairingGeneratorUsesCanonicalAlphabetAndRejectsBiasedBytes`
  - `testRunningWorkspaceRendersAtSupportedSizesAndAppearances`
  - `testCompactHeaderFitsSupportedLocalesAndIdentityFailureAtMinimumWidth`
  - Exit code: `0`
- Maintained Viewer suite with code signing disabled:
  - Exit code: `0`
  - Excluded the existing unsigned-entitlement assertion and the existing Xcode 26.5 test-host
    localization-source-scan hang. No entitlement or localization source is changed by this scope.

The render checks cover supported window sizes and appearances, compact-header localization, the
36-point pairing-code prominence, and absence of clipping.

## Demo and packaging

- SwiftPM Demo Xcode project build for the generic iOS Simulator:
  - Exit code: `0`
- CocoaPods Demo workspace:
  - Not present in the repository because generated Pods artifacts are not checked in.
- `pod ipc spec NearWire.podspec`
  - Exit code: `0`
- `pod lib lint NearWire.podspec --allow-warnings --skip-tests`
  - Exit code: `0`
  - Result: `NearWire passed validation.`
  - This lint was rerun after the final SDK Core-import guard was applied, so it validates the
    CocoaPods single-module source layout as well as the SwiftPM layout covered by `swift test`.

## Repository hygiene

- `git diff --check`
  - Exit code: `0`
- `swift-format lint --strict` passed for the changed pairing, SDK error, and test files except for
  known pre-existing findings in `ViewerRootView.swift` outside the changed pairing-code line and
  pre-existing `forEach` findings in `ViewerFoundationTests.swift`. This change does not rewrite
  unrelated formatting.
- The residue results and ownership audit are recorded in `hardcoded-assumption-audit.md`.
