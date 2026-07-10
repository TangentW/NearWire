# Review Round 2

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P1: CocoaPods evidence contradicted the strict lint result

The first round 2 capture retained a failed CocoaPods log while the summary claimed success.

Resolution: replace public-release placeholder validation with the documented private-spec workflow for this internal product, use network-verifiable bootstrap metadata, retain import validation, prohibit `--allow-warnings`, rerun strict lint, and replace the raw log. The current log ends with `NearWire passed validation` and exit 0 and contains no CocoaPods `WARN` result.

### P1: SDK tests were not executed on iOS

The earlier package gate cross-compiled SDK sources for iOS but executed all tests only on the macOS host, which would not support future UIKit-based SDK targets.

Resolution: execute all seven package tests on an iPhone Simulator, record the xcresult summary, and use a dedicated Core-only package harness for macOS tests. Keep explicit iOS 16 all-target and macOS 13 Core-target builds.

### P2: Swift import boundary checks were bypassable

Attributed, access-qualified, and declaration-specific platform UI imports could bypass the initial Core import regular expression.

Resolution: replace the shell expression with a Swift import parser that recognizes valid modifier and declaration forms. Add negative fixtures for implementation-only, preconcurrency, public, declaration-specific, and internal re-export imports.

### P2: Root CocoaPods dependencies were not inspected

The initial pod boundary gate inspected subspec dependencies but not dependencies declared on the root specification.

Resolution: recursively validate the root specification and every subspec, and add negative fixtures for root and subspec external dependencies.

## Round Status

Every round 2 finding has a recorded remediation and passing automated evidence. A fresh review round is still required before archive.
