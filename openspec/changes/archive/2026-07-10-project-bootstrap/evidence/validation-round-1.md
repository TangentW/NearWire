# Validation Evidence: Round 1

> Superseded by round 2. Independent review identified missing iOS SwiftPM coverage, skipped CocoaPods import validation, non-failing concurrency warnings, incomplete boundary automation, and summary-only evidence. This file is retained as an exact record of the first validation attempt, not as final completion proof.

## Environment

- Date: 2026-07-11
- Xcode: 26.6 (build 17F113), satisfying the Xcode 16 minimum
- Swift compiler: 6.3.3 in Swift 5 language mode
- CocoaPods: 1.16.2
- OpenSpec: 1.2.0

## OpenSpec Artifact Validation

Command:

```sh
DO_NOT_TRACK=1 openspec validate project-bootstrap --strict
```

Result: exit 0, `Change 'project-bootstrap' is valid`.

## Complete Bootstrap Gate

Command:

```sh
./Scripts/verify-bootstrap.sh
```

The command was granted CoreSimulator access because CocoaPods lint invokes `simctl` and Xcode build services.

Result: exit 0.

Verified gates:

- Repository structure, nested manifest count, shell syntax, podspec Ruby syntax, and workspace XML: passed.
- English-language scan for new repository content: passed.
- `VERSION` and podspec version agreement at `0.1.0`: passed.
- Swift Package describe and build: passed.
- Seven Swift Package smoke tests: passed with zero failures.
- Strict-concurrency diagnostic build: passed.
- CocoaPods source compilation for Core, SDK, UI, and Performance subspecs: passed, but round 1 skipped consumer import validation and allowed a known metadata warning. Round 2 replaces this gate.

Expected non-production warning:

- CocoaPods reported that `https://example.invalid/nearwire` is not reachable. The URL is deliberately non-production metadata and is documented as pending release engineering. `--allow-warnings` does not suppress compile or validation errors.

## Initial Sandboxed Attempts

The first SwiftPM attempt failed because SwiftPM and Clang attempted to write user cache directories and to launch a nested sandbox. The verification script was corrected to use repository-local ignored caches and `--disable-sandbox`; the same package build and test commands then passed.

The first CocoaPods attempt inside the restricted sandbox could not connect to CoreSimulatorService. The unchanged podspec lint command passed after receiving the required CoreSimulator access. No product requirement or validation level was weakened.
