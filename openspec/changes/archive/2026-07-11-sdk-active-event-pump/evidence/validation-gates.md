# Validation Gates

## Full Strict-Concurrency Package

- Command: `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-cache swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
- Finished: 2026-07-12 03:41:32 +08:00.
- Result: 361 tests executed, 361 passed, 0 skipped, 0 failed in 1.030 seconds.
- Compiler mode: Swift 5 language mode, complete strict concurrency, warnings treated as errors.

## Repository Packaging Gate

- Command: `./Scripts/verify-package.sh`
- Finished: 2026-07-12 04:00:38 +08:00.
- Result: passed.
- iOS Simulator Swift Package test result: 361 total, 360 passed, 1 platform-expected skip, 0 failed.
- Platform-neutral Core harness: 193 passed, 0 failed.
- Real production TLS active-session filter: 1 passed, 0 skipped, 0 failed. It performed admission handoff, policy activation, bidirectional Events, queue drain, and terminal teardown.
- SwiftPM SDK consumer API, implementation-type sealing, wire payload sealing, mandatory-TLS boundary, raw-connection boundaries, Core package parity, CocoaPods same-module API parity, and process-lease multi-image checks passed.
- The first run stopped because the previous session-admission structure checker still prohibited Event payloads. The checker was updated to require the new internal active-pump components while retaining process-lease, public-state, raw-connection, implementation-only, and queue-ownership prohibitions. The complete gate was then rerun from the beginning and passed.

## CocoaPods

- Command: `./Scripts/verify-podspec.sh`
- CocoaPods: 1.16.2.
- Finished: 2026-07-12 04:02:24 +08:00.
- Result: `NearWire passed validation` and `CocoaPods podspec verification passed`.
- All Core, SDK, UI, and Performance subspec build checks passed.
- Expected repository placeholder warning: `https://example.invalid/nearwire`; no build or lint error.

## Static Repository Gates

- `./Scripts/verify-boundaries.sh`: passed all Swift import, Core SPI, secure-transport construction, SwiftPM, CocoaPods, distribution, and dependency-isolation checks.
- `./Scripts/verify-structure.sh`: passed.
- `./Scripts/verify-english.sh`: passed the CJK scan; documentation was also manually reviewed for English semantics.
- `./Scripts/verify-version.sh`: passed for `0.1.0`.
- `./Scripts/Tests/validation-tools.sh`: passed evidence-capture, simulator-state, and distribution-contract mutation tests.
- `swift format lint --recursive --strict Core SDK Package.swift`: passed.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: passed.
- `git diff --check`: passed with no output.
