# Validation Evidence: Round 2

This snapshot is superseded by `validation-round-4.md`. It is retained to preserve the review history.

## Purpose

Round 2 reruns the complete validation suite after remediating every round 1 review finding. Verbatim stdout, stderr, commands, timestamps, and exit statuses are stored in `evidence/round-2-raw`.

## Raw Evidence Index

| Sequence | Gate | Raw log | Result |
|---:|---|---|---|
| 01 | Toolchain environment | `round-2-raw/01-environment.log` | Exit 0 |
| 02 | OpenSpec strict validation | `round-2-raw/02-openspec.log` | Exit 0 |
| 03 | Structure, script syntax, podspec syntax, workspace XML | `round-2-raw/03-structure.log` | Exit 0 |
| 04 | Mechanical CJK-language scan | `round-2-raw/04-language.log` | Exit 0 |
| 05 | SemVer and CocoaPods version checker tests | `round-2-raw/05-validation-tools.log` | Exit 0 |
| 06 | Product version agreement | `round-2-raw/06-version.log` | Exit 0 |
| 07 | Module boundaries and dependency isolation | `round-2-raw/07-boundaries.log` | Exit 0 |
| 08 | SwiftPM resolve, iOS 16 build and simulator tests, macOS 13 Core builds and Core tests, strict concurrency | `round-2-raw/08-swift-package.log` | Exit 0 |
| 09 | CocoaPods 1.16 minimum and warning-clean import lint for all subspecs | `round-2-raw/09-cocoapods.log` | Exit 0 |

## Coverage Added After Round 1

- Explicit `swift package resolve` with repository-local cache paths.
- SwiftPM build of all SDK targets for `arm64-apple-ios16.0`.
- All seven SwiftPM tests executed on an iPhone Simulator with an xcresult summary recording seven passed and zero failed.
- SwiftPM builds of NearWireCore, NearWireTransport, and NearWireFlowControl for `arm64-apple-macosx13.0`.
- Four Core-only tests executed through a dedicated macOS package harness, preventing future iOS-only SDK sources from entering the host test graph.
- Strict-concurrency diagnostics compiled with warnings as errors.
- CocoaPods import validation with no `--allow-warnings` or `--skip-import-validation` escape hatch.
- Automated root-package dependency, recursive pod dependency, target-path, modifier-aware Core UI import, and internal re-export checks.
- Negative boundary fixtures for attributed and declaration-specific Swift imports and root or subspec external pod dependencies.
- SemVer 2.0 positive and negative tests.
- CocoaPods minimum-version positive and negative tests.
- Root proprietary license and package metadata language coverage.

## Expected Tool Notes

CocoaPods reports Xcode App Intents metadata extraction messages as `NOTE` entries because the placeholder targets do not link AppIntents. CocoaPods itself reports no lint warning and returns exit 0. SwiftPM package, configuration, security, scratch, and module caches are redirected to ignored repository-local or temporary paths, and every build and test returns exit 0.

The mechanical language gate only detects CJK scripts. Semantic English compliance remains a required human and agent review dimension and is not overstated as mechanically proven.
