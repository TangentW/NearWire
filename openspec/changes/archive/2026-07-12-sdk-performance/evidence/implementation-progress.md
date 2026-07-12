# Implementation Progress Evidence

Date: 2026-07-12

## Public API, lifecycle, projection, and deterministic tests

Command:

```text
HOME=/Users/tangent/Desktop/RemoteLens/.build/home XDG_CACHE_HOME=/Users/tangent/Desktop/RemoteLens/.build/cache CLANG_MODULE_CACHE_PATH=/Users/tangent/Desktop/RemoteLens/.build/ModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/Users/tangent/Desktop/RemoteLens/.build/ModuleCache swift test --disable-sandbox --filter NearWirePerformanceTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Current focused result after review remediation: passed. XCTest executed 51 macOS-compatible Performance tests with zero failures in 0.420 seconds. The final iOS simulator count will be refreshed by the canonical recapture. The deterministic gates include 1,000 fake-resource start/stop cycles, 10,000 aggregate projections, and 10,000 ordinary NearWire keep-latest admissions.

Covered evidence includes configuration bounds, half-up elapsed rounding, initial and recovered CPU baselines, multi-core and invalid CPU values, display callback formula/reset/invalid timestamps, exact unavailable inventory and precedence, permission-denied distinction, JSON parity, installation-correlated envelope decoding, JSON-safe drop saturation, disabled-group zero work, first-after-interval behavior, delayed no-catch-up scheduling, same-attempt concurrent start, exact-instance lease contention, pre-start cancellation, stop during setup, explicit/failure cleanup barriers, late noncooperative failure rejection, stream cancellation and restart retention, macOS unsupported start, and exact terminal cleanup counters.

## iOS 16 distributed-source and test-source compilation

Command:

```text
HOME=/Users/tangent/Desktop/RemoteLens/.build/home XDG_CACHE_HOME=/Users/tangent/Desktop/RemoteLens/.build/cache CLANG_MODULE_CACHE_PATH=/Users/tangent/Desktop/RemoteLens/.build/ModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/Users/tangent/Desktop/RemoteLens/.build/ModuleCache swift build --disable-sandbox --scratch-path /Users/tangent/Desktop/RemoteLens/.build/performance-ios-tests --triple arm64-apple-ios16.0 --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk --build-tests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Result: passed. The complete Core, SDK, UI, Performance, and test source graph compiled for arm64 iOS 16 in Swift 5 language mode with complete concurrency and warnings as errors. Both target-owned privacy manifests were copied as resources.

## Packaging boundaries and privacy manifests

Commands:

```text
./Scripts/verify-boundaries.sh
plutil -lint SDK/Sources/NearWire/PrivacyInfo.xcprivacy SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy
```

Results:

```text
Module boundary and dependency isolation verification passed.
SDK/Sources/NearWire/PrivacyInfo.xcprivacy: OK
SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy: OK
```

The supported public surface is configuration, safe error/code, lifecycle state, and actor monitor. Internal snapshot, metric, collector, clock, lease, and run declarations remain unavailable through Swift access control. The focused suite parses both source manifests into keyed property-list records and verifies the owned collected-data type, linked/tracking values, purpose, omitted tracking domains, and omitted Required Reason array. The package gate is intentionally limited to real SwiftPM/CocoaPods consumer compilation and packaged-resource presence.
