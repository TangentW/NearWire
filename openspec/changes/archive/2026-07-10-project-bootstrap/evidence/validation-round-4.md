# Validation Evidence: Round 10

## Purpose

This is the canonical validation suite after remediating every finding from review rounds 1 through 9. Canonical run `20260710T213802Z-20165` stores verbatim stdout, stderr, commands, gate identities, run IDs, timestamps, and exit statuses in `evidence/round-2-raw`; the same run ID is recorded by `all-capture-status.log`. The summary filename and raw directory name are retained to preserve existing review references.

## Atomic Capture Integrity

`all-capture-status.log` records one completed canonical run. Every numbered log has the same run ID, every numbered log exits 0, and the capture command verifies those invariants before reporting success. A regression test seeds a stale later log, forces an early capture failure, and proves the stale log is removed and the incomplete run cannot pass evidence verification.

## Raw Evidence Index

| Sequence | Gate | Raw log | Result |
|---:|---|---|---|
| Status | Atomic canonical run manifest | `round-2-raw/all-capture-status.log` | Complete, exit 0 |
| 01 | Toolchain environment | `round-2-raw/01-environment.log` | Exit 0 |
| 02 | OpenSpec strict validation | `round-2-raw/02-openspec.log` | Exit 0 |
| 03 | Structure, script syntax, podspec syntax, workspace XML | `round-2-raw/03-structure.log` | Exit 0 |
| 04 | Mechanical CJK-language scan | `round-2-raw/04-language.log` | Exit 0 |
| 05 | SemVer, CocoaPods version, boundary mutation, parity, and evidence failure tests | `round-2-raw/05-validation-tools.log` | Exit 0 |
| 06 | Product version agreement | `round-2-raw/06-version.log` | Exit 0 |
| 07 | Module boundaries, path containment, and dependency isolation | `round-2-raw/07-boundaries.log` | Exit 0 |
| 08 | SwiftPM resolve, Core graph parity, iOS 16 build and tests, macOS 13 Core builds and Core tests, strict concurrency | `round-2-raw/08-swift-package.log` | Exit 0 |
| 09 | CocoaPods 1.16 minimum and private import lint for every subspec | `round-2-raw/09-cocoapods.log` | Exit 0 |

## Platform and Test Coverage

- All SDK targets compile for `arm64-apple-ios16.0` in Swift 5 language mode with complete concurrency checking and warnings as errors.
- All seven SwiftPM tests execute on an iPhone Simulator; xcresult reports seven passed, zero failed, and zero skipped.
- Every regular Core target is derived from the root package graph and compiles for `arm64-apple-macosx13.0`.
- Four Core-only tests execute through a dedicated macOS package harness.
- The Core harness is compared with the root package for normalized target names, types, paths, and dependencies before use.
- The verifier preserves an already-booted simulator and shuts down a simulator that it booted, on both success and failure. A restoration failure fails an otherwise successful gate, while an existing primary failure remains authoritative.

## Boundary and Failure Coverage

- The Swift compiler parser identifies platform imports hidden by comments or declaration-specific syntax and exported or public Core imports whose modifier is on the same or a preceding line.
- SwiftPM and CocoaPods path checks reject absolute paths, parent traversal, brace-expanded traversal, and symlink escapes before normalized and realpath ownership checks.
- Root, recursive subspec, and platform-specific pod dependencies are restricted to internal NearWire dependencies.
- CocoaPods source, header, and resource-bearing paths are ownership-checked at root, subspec, and platform levels. Vendored binaries, executable integration hooks, custom compilation files, unsupported child specs, and arbitrary build-setting injection are forbidden.
- Mutation tests cover invalid semantic versions, unsupported CocoaPods versions, forbidden imports, exported and public re-exports, root and subspec dependencies, traversal and symlink paths, complete Core graph drift, stale evidence capture, and Simulator cleanup failure.
- Root-package external dependencies, unauthorized target roots, and SDK Core re-exports fail the gate.
- Exact SwiftPM product linkage and complete target descriptors, plus CocoaPods provenance, module, platform, default subspec, complete dependency graph, build settings, and source mappings, are locked by a mutation-tested distribution contract.

## Expected Tool Results

CocoaPods private lint emits one public-release-only URL warning because the bootstrap homepage intentionally uses the reserved, non-resolving `example.invalid` namespace. Private lint still compiles and imports Core, SDK, UI, and Performance, reports `NearWire passed validation`, and exits 0. Xcode App Intents metadata extraction messages are classified by CocoaPods as `NOTE` entries because placeholder targets do not link AppIntents.

The placeholder URL cannot resolve to an unrelated owner and must be replaced by an authorized internal HTTPS location before distribution. Private lint does not prove remote ownership or availability. Compiler, import, concurrency, and other non-public validation warnings remain failures.

The mechanical language gate detects CJK scripts. Semantic English compliance remains a required human and agent review dimension and is not overstated as mechanically proven.
