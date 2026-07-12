# Final Validation

Date: 2026-07-12, Asia/Shanghai

Status: complete for the final reviewed tree.

## Canonical run

The repository evidence harness ran with ID `20260712T101542Z-40669`. The complete status is stored in `raw/all-capture-status.log`; every command, timestamp, output, and exit status is stored in `raw/01-environment.log` through `raw/09-cocoapods.log`.

Environment:

- Xcode 26.6, build 17F113
- Apple Swift 6.3.3 compiler, distributed sources compiled in Swift 5 language mode
- CocoaPods 1.16.2
- OpenSpec 1.2.0

Results:

- Strict OpenSpec: 27 items passed, 0 failed.
- Structure, English, validation-tool mutation tests, version 0.1.0, and module boundaries: passed.
- iOS Simulator on iPhone 17 Pro / iOS 26.4: 517 passed, 4 skipped, 0 failed, 521 total.
- Isolated Core harness: 196 passed, 0 failed.
- Real TLS admission and public-connect integration: one exact test passed in each gate.
- SwiftPM distributed-source/test compilation, small consumer checks, privacy-resource packaging, macOS fallback, and integration validation: passed.
- CocoaPods lint, SDK-only isolation, Performance subspec, small consumer compilation, and framework isolation: passed. The only lint warning is the intentional placeholder URL `https://example.invalid/nearwire`.

The final run includes the Round 1 through Round 4 remediation tree and the deliberately simplified validation strategy:

```text
DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive
Change 'sdk-performance' is valid

./Scripts/verify-structure.sh
Repository structure verification passed.

./Scripts/verify-english.sh
CJK character scan passed. Human review remains required for semantic language compliance.

git diff --check
passed with no output
```

The separate focused Performance command executed 51 tests with zero failures in 0.420 seconds. It includes structured privacy-manifest assertions and explicitly gated lifecycle arrival checks without fixed scheduler-yield loops. The canonical run then compiled and executed the complete iOS test graph with complete concurrency and warnings as errors. Exact focused command:

```text
HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --disable-sandbox --filter NearWirePerformanceTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```
