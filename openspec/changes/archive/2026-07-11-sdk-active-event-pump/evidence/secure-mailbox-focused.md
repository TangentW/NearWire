# Reserved Secure Mailbox Focused Evidence

## Implementation

- Added overflow-safe per-admission pending-count and pending-byte reservations.
- Preserved the original zero-reservation synchronous and actor-isolated admission behavior.
- Added a constant-size accepting/count/byte/progress capacity snapshot.
- Added a non-retaining known-encoded-size capacity predicate that remains advisory to atomic admission.
- Progress generation advances when completion releases retained capacity and when terminal transition closes admission.

## Focused Test Run

- Command: `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-cache swift test --filter SecureByteChannelTests`
- Finished: 2026-07-12 00:34:54 +08:00
- Platform: `arm64e-apple-macos14.0`
- Result: 28 tests executed, 28 passed, 0 skipped, 0 failed in 0.010 seconds.
- New coverage includes exact reservation count/bytes, invalid reservation atomicity, advisory predicate/no retention, completion and terminal progress, concurrent reserved admissions, and terminal cleanup.

## Transport Regression Run

- Command: `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-cache swift test --filter NearWireTransportTests`
- Finished: 2026-07-12 00:35:57 +08:00
- Platform: `arm64e-apple-macos14.0`
- Result: 94 tests executed, 94 passed, 0 skipped, 0 failed in 0.143 seconds.
- The production App/Viewer TLS 1.3 ALPN handshake test passed in 0.013 seconds.

## Formatting and Validation

- `swift format lint Core/Sources/NearWireTransport/SecureByteChannel.swift Core/Tests/NearWireTransportTests/SecureByteChannelTests.swift`: passed with no output.
- `git diff --check`: passed with no output.
- The first sandboxed SwiftPM attempts failed because Xcode could not write its module cache and nested `sandbox-exec` was denied. The intended commands were rerun outside the nested sandbox with caches under `/tmp`; both completed successfully as recorded above.
