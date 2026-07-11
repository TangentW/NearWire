# SDK Pairing Discovery Final Validation

## Run Identity

- Captured: `2026-07-11T07:58:59Z`
- Base commit: `3c921b48b6251b1608b8b7d13b58a9d031f51c58`
- Xcode: `26.6 (17F113)`
- Swift: `6.3.3`, compiled in Swift 5 language mode
- CocoaPods: `1.16.2`
- OpenSpec: `1.2.0`
- Required compatibility targets: iOS 16 and macOS 13

## Focused Strict-Concurrency Gate

Command:

```text
HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --manifest-cache local --disable-dependency-cache --disable-build-manifest-caching --disable-sandbox --filter 'PairingDiscoveryIdentityTests|ViewerDiscoveryTests|BonjourBrowserAdapterTests' -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Result: passed, 36 tests executed, 0 failures, 0 skipped.

The focused suite covers the complete pairing alphabet and separators, input work limits, hostile controls and bidi text, CryptoKit vectors, exact identity, `vid` attribution and ambiguity, duplicate-ready epochs, first-terminal latching, already-cancelled tasks, cancellation/result races, snapshot replacement, cumulative saturated discard telemetry, callback coalescing, candidate and canonical-identity byte bounds, production plan inputs, private serial queue use, callback release, and result-limit failure.

## Full Package Gate

Command:

```text
./Scripts/verify-package.sh
```

Result: passed.

Exact archive-candidate results:

- Core package fixture parity passed.
- Strict iOS 16 SwiftPM build passed in Swift 5 language mode.
- Canonical iOS SwiftPM consumers compiled.
- Strict macOS 13 Core and NearWire builds passed.
- SwiftPM supported API and implementation-type boundaries passed.
- CocoaPods same-module consumer compilation and SwiftPM/CocoaPods API inventory parity passed.
- Wire payload sealing, mandatory TLS, raw-connection construction, same-module transport, and identity-lifecycle boundaries passed.
- iOS Simulator tests: 226 passed, 0 failed, 0 skipped on iPhone 17 Pro / iOS 26.4 Simulator.
- macOS Core harness tests: 165 passed, 0 failed, 0 skipped.
- Production TLS 1.3 and ALPN tests executed rather than skipping.

## CocoaPods Gate

Command:

```text
./Scripts/verify-podspec.sh
```

Result: passed.

`NearWire (0.1.0)` and all Core, SDK, UI, and Performance subspec build paths passed validation. The only warning was the expected reserved bootstrap homepage `https://example.invalid/nearwire`. AppIntents metadata extraction notes are expected because NearWire does not depend on AppIntents. There were no build or test errors.

## Repository Gates

Commands:

```text
DO_NOT_TRACK=1 openspec validate sdk-pairing-discovery --strict --no-interactive
./Scripts/verify-boundaries.sh
./Scripts/verify-structure.sh
./Scripts/verify-english.sh
./Scripts/Tests/validation-tools.sh
./Scripts/verify-version.sh
swift format lint --recursive Package.swift Core SDK Scripts/Fixtures
git diff --check
```

Results: passed.

- OpenSpec proposal, design, capability deltas, tasks, and scenarios are strictly valid.
- Swift module, Core SPI, secure-construction, package, pod, and exact distribution boundaries passed.
- Repository layout and all validation-script executable checks passed. The pre-existing Core SPI checker mode was restored from `100644` to `100755`; file contents are unchanged.
- CJK scanning passed, and independent semantic documentation review reported zero findings.
- Evidence-capture, simulator-restoration, distribution-mutation, and validation-tool regressions passed.
- Version sources agree on `0.1.0`.
- Formatting and whitespace checks passed.

## Supported API Inventory

The supported `NearWire` application API is unchanged. Pairing code, Bonjour identity, discovery state, driver, callback edge, snapshot, and matched endpoint types are repository-only Core SPI or SDK-internal declarations. No supported signature exposes Network.framework, CryptoKit, Core, transport, discovery, endpoint, pairing, or `vid` implementation types.

## Residual Scope

This change intentionally adds no public `connect` or `disconnect`, TLS connection attempt, process-wide lease, persistence, Keychain access, hello/admission handshake, flow scheduling, retry timer, background observer, UI, Viewer publisher, or event transfer. Those remain in the named active-session, connection-lifecycle, SDK UI, and Viewer changes.
