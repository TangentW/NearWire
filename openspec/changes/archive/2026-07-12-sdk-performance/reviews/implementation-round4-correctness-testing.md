# Implementation Round 4 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently re-reviewed the current active `sdk-performance` tree after the generic Swift boundary validator was simplified from isolated compiler parsing to lexical token inspection. The review covered the current validator implementation, its positive and mutation fixtures, the complete boundary gate, current evidence/task language, the 51-test Performance suite, active specifications, prior implementation reviews, and Git status/diff. This report is the only file modified.

## Findings

**Zero actionable findings.**

## Verification

### Validator scope and correctness

`Scripts/check-swift-boundaries.rb` now performs one narrow job: it inventories Swift import declarations while skipping line comments, nested block comments, ordinary strings, raw strings, and multiline strings, then rejects platform UI imports from Core and public/exported internal-Core imports from SDK (`Scripts/check-swift-boundaries.rb:16-143`). It handles scoped imports such as `import class UIKit.UIView`, common import attributes/modifiers, and modifiers separated from `import` by line breaks. It reports source paths and lexer-maintained line numbers without invoking the compiler on incomplete single-file fragments.

That is an appropriate correction for the Round 3 compiler-crash finding. The validator does not claim to resolve declarations, type-check supported signatures, compile consumers, or prove runtime behavior. Those concerns remain assigned to the Core SPI validator, package/pod dependency checks, real SwiftPM/CocoaPods consumer builds, and XCTest. Token inspection is therefore a conservative import/re-export gate rather than a false behavioral substitute.

### Positive and mutation coverage

The existing validation-tool suite is proportionate to the validator's stated responsibility:

- an allowed Core/SDK fixture passes the Swift boundary scan (`Scripts/Tests/validation-tools.sh:56-69`);
- Core mutations cover implementation-only, preconcurrency, public, scoped, and comment-prefixed platform imports (`validation-tools.sh:147-164`);
- a block-comment-only `import UIKit` fixture passes, guarding against the primary lexical false-positive class (`validation-tools.sh:167-173`);
- SDK mutations reject exported and public internal-Core imports in both single-line and multiline forms (`validation-tools.sh:175-213`).

The full validation-tool suite passes, so each mutation is observed to fail for the expected gate while the positive fixtures pass. Adding a compiler-backed parser or exhaustive Swift lexer solely for this import policy would reintroduce complexity without proportionate correctness value.

### Evidence and behavior claims

Current product and OpenSpec language keeps the layers distinct. The design assigns supported API evidence to small real consumers and runtime correctness to XCTest (`openspec/changes/sdk-performance/design.md:211-217`). The Performance specification explicitly requires real SwiftPM/CocoaPods consumer smoke checks and says packaging validation must not duplicate runtime XCTest behavior with source-text machinery (`specs/sdk-performance/spec.md:204-210`). Tasks 4.2 through 4.6 likewise separate deterministic behavior, iOS smoke coverage, consumer fixtures, and packaging checks (`tasks.md:24-28`).

The interim spec-to-evidence audit attributes supported API use to consumer compilation and describes the final canonical package evidence as pending; it does not present the lexical import scan as public API or behavioral proof (`evidence/spec-to-evidence-audit.md:1-15`). The generic boundary message, “Swift module import boundaries passed,” accurately describes the validator output. The aggregate `verify-boundaries.sh` success message is supported by separate SPI, secure-transport, package, podspec, and distribution-contract checks, not by token inspection alone.

### Product consistency

The validator change does not touch production or product test source. The current 51 focused Performance tests still pass with complete concurrency checking and warnings as errors. Lifecycle cancellation/commit winners, cleanup ordering, sampling epoch and CPU/FPS math, unavailable projection, queue behavior, stress bounds, privacy semantics, and macOS fallback remain consistent with the active specification. Strict OpenSpec validation and whitespace/error checks also pass.

## Validation Performed

- `./Scripts/Tests/validation-tools.sh`: **PASS**; validation positive and mutation tests passed.
- `./Scripts/verify-boundaries.sh`: **PASS**; Swift import, Core SPI, secure transport, SwiftPM, CocoaPods, and distribution boundaries passed.
- `HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --disable-sandbox --filter NearWirePerformanceTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: **PASS**, 51 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.
- No production, specification, test, evidence, documentation, package, manifest, script, or prior review file was modified by this review.

## Verdict

**Implementation correctness/testing approval granted. Exact unresolved actionable finding count: 0.**
