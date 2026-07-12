# Validation Gates

## Focused and full tests

| Command | Result |
| --- | --- |
| `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-final2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-final2-swiftpm swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnection` | Passed: 38 tests, 0 failures |
| `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKSessionAdmissionTests/testPublicAdmissionCancellationOwner` | Passed: 2 tests, 0 failures |
| `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter WireEventTests/testMaximumRecordTraversesProductionSessionCodecAtExactBoundary` | Passed: 1 test, 0 failures |
| `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-final-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-final-swiftpm swift test --disable-sandbox --quiet -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` | Passed before the final lock-local read patch: 405 tests, 7 platform skips, 0 failures. The subsequent aggregate iOS gate compiled and ran the final source. |
| unrestricted `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKSessionAdmissionTests.testPublicConnectUsesProductionTLSBidirectionalEventsAndRealProcessLease` | Passed: 1 test, 0 failures; production Network.framework TLS and trust evaluation were exercised |

Earlier full-suite runs reported transient failures in truncated console output; each immediate diagnostic rerun passed. The strict run passed all 405 then-existing tests, and the final independent iOS package suite compiled the lock-local read patch and passed all 406 current tests. This history is retained rather than hidden.

## Distribution

| Command | Result |
| --- | --- |
| unrestricted `./Scripts/verify-package.sh` | Passed after the final lock-discipline fix. iOS simulator: 406 total, 402 passed, 4 platform skips; Core harness: 196 passed; public/internal API boundaries passed; internal production TLS admission 1/1 passed; supported public-connect production TLS 1/1 passed without skipping. |
| unrestricted `./Scripts/verify-podspec.sh` | Passed with the expected placeholder-URL warning; CocoaPods 1.16.2 built Core, SDK, UI, and Performance subspecs. |

## Static and repository gates

The following commands passed without weakening their checks:

- `./Scripts/verify-boundaries.sh`
- `./Scripts/verify-structure.sh`
- `./Scripts/verify-english.sh`
- `./Scripts/verify-version.sh`
- `./Scripts/Tests/validation-tools.sh`
- `swift format lint --strict --recursive Package.swift Core SDK`
- `git diff --check`
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`

Both aggregate distribution gates were rerun after Round 2 remediation. CocoaPods emitted only its expected placeholder-URL warning and AppIntents metadata notes.

Preserved aggregate summaries:

- `logs/final-package-summary.log`
- `logs/final-podspec-summary.log`

Their SHA-256 hashes are recorded in `logs/SHA256SUMS` after the final evidence edit.
