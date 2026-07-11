# Validation Evidence Before Simulator Completion

Captured at `2026-07-11T02:28:05Z` from base commit `c6f4515` with the active `sdk-public-api` working tree.

## Passing Validation

- `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - 190 tests executed.
  - 0 failures.
  - 5 expected skips because Security trust or Network services are unavailable in the restricted sandbox.
- Focused queue, secure-channel, SDK event, and SDK buffer regressions passed before the full run.
- `DO_NOT_TRACK=1 openspec validate sdk-public-api --strict --no-interactive` passed.
- `Scripts/verify-boundaries.sh` passed Swift imports, Core SPI visibility, secure transport construction, package paths/dependencies, pod paths/dependencies, and the exact distribution manifest contract.
- `Scripts/verify-english.sh` passed the CJK scan; the review agents also inspected the English documentation semantically.
- `Scripts/Tests/validation-tools.sh` passed evidence-failure, simulator-restoration, distribution-mutation, and validation-tool tests.
- `git diff --check` passed.
- `Scripts/verify-package.sh` passed all work before simulator startup:
  - Core package fixture parity.
  - Strict iOS 16 SwiftPM build in Swift 5 language mode.
  - Canonical iOS SwiftPM SDK and built-in SPI consumer compilation.
  - Strict macOS 13 Core and SDK builds.
  - SDK implementation-type API boundary.
  - Canonical iOS CocoaPods same-module consumer compilation.
  - iOS-to-iOS SwiftPM/CocoaPods non-SPI API inventory parity.
  - Wire payload sealing, mandatory TLS, raw connection wrapping, and transport identity lifecycle boundaries.

## Environment Blocker

The required iOS Simulator package tests and full `pod lib lint` cannot start because the managed sandbox cannot connect to `CoreSimulatorService` or its disk-image service. The unrestricted validation request was rejected by the execution environment because its approval usage limit had been reached. No workaround was attempted.

This change is intentionally not marked complete, archived, or committed until those two platform gates pass.

