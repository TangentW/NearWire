# Implementation Review Round 4 — Architecture and API

Date: 2026-07-12

## Scope

Independently reviewed the current `sdk-performance` shared tree after remediation of the sole Round 3 architecture/API finding. The review covered the generic Swift import-boundary validator and its mutation coverage, repeated boundary-gate behavior, SwiftPM and CocoaPods dependency isolation, the public Performance API, setup/run ownership, activation authorization, cancellation versus final commit, the documented activation-to-actor scheduling tolerance, active tasks, and evidence truthfulness. The intentionally deleted Performance-specific structure/mutation script was not treated as required, and no production, specification, test, or evidence file was modified by this review.

## Findings

No unresolved actionable architecture/API finding was identified.

## Round 3 Finding Disposition

### Required boundary gate crash and inaccurate current evidence — resolved

`Scripts/check-swift-boundaries.rb` no longer invokes `xcrun swiftc -frontend -dump-parse` on isolated source files. It now uses its existing comment/string-aware tokenizer to find import declarations, records source lines, handles typed imports such as `import class UIKit.UIView`, and recognizes both `public import` and `@_exported import`, including their multiline forms. This removes the compiler-crash path without reintroducing a Performance-specific validator or a heavyweight parallel API-digester framework.

The validation-tool suite exercises allowed input, forbidden Core platform imports with attributes and typed-import syntax, comment-only false-positive resistance, and same-line/multiline `@_exported` and `public` internal-Core re-exports. It passed in this review. `./Scripts/verify-boundaries.sh` also passed three consecutive independent runs and continued through Core SPI, secure transport construction, SwiftPM, CocoaPods, and cross-manifest distribution checks each time.

The evidence statements are now true for the current tree: `evidence/implementation-progress.md` records the boundary command and successful result, and `evidence/spec-to-evidence-audit.md` cites it only as current focused boundary evidence. Neither document claims that focused evidence is the final canonical capture. `evidence/final-validation.md` still labels canonical recapture as pending, and tasks 5.2 and 5.3 remain unchecked until the complete validation and spec-to-evidence gates are rerun.

## Architecture and API Revalidation

- The supported public Performance surface remains limited to configuration, fixed safe error/code, lifecycle state, and the actor monitor. Snapshot/schema, collector, runtime, clock, monitor lease, setup/run workers, acquisition gates, and test seams remain internal.
- Activation authorization closes later setup acquisition without discarding cancellation. The final actor commit uses the attempt lock to choose exactly one cancellation-versus-commit winner, then creates the run worker, publishes Running, and resolves the shared attempt in the same non-suspending actor turn.
- Setup-owned collector and lease handles transfer only after that final commit succeeds. A cancellation or rejected commit follows the existing ordered cleanup path, stopping the collector before releasing the lease.
- The bounded activation-to-actor scheduling gap remains explicitly allowed by the active design/specification. Successful commit may include that small gap in the first interval/display accumulator; cancellation-winning cleanup discards the activated state. No implementation/spec mismatch was found.
- SwiftPM and CocoaPods retain equivalent optional Performance exposure and base-SDK dependency isolation. Core and SDK remain free of third-party runtime dependencies, while UIKit and QuartzCore stay confined to the optional Performance product/subspec.
- The narrowed validation design remains proportionate: small real package consumers and resource checks own packaging evidence; XCTest owns behavior and privacy-manifest semantics; the generic repository boundary tools own cross-module dependency rules.

## Validation Performed by This Review

- `./Scripts/verify-boundaries.sh`, three consecutive runs: **PASS**. Each run completed Swift import, Core SPI, secure transport, SwiftPM, CocoaPods, and distribution-contract boundaries.
- `./Scripts/Tests/validation-tools.sh`: **PASS**, including Swift import/re-export mutations.
- Focused Performance suite with complete concurrency and warnings as errors: **PASS**, 51 tests, 0 failures.
- `plutil -lint SDK/Sources/NearWire/PrivacyInfo.xcprivacy SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `./Scripts/verify-english.sh`: **PASS**.
- `git diff --check`: **PASS**.

## Verdict

**Implementation architecture/API approval granted. Exact unresolved actionable finding count: 0.**
