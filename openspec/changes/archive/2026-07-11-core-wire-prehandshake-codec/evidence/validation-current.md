# Core Wire Pre-Handshake Codec Validation

## Run Identity

- Initial capture: `2026-07-11T09:37:08Z`
- Final simulator rerun: `2026-07-11T12:35:11Z`
- Base commit: `3d998d9813a3b02e6229cb85067c33548181417e`
- Xcode: `26.6 (17F113)`
- Swift: `6.3.3`, compiled in Swift 5 language mode
- CocoaPods: `1.16.2`
- OpenSpec: `1.2.0`
- Required compatibility targets: iOS 16 and macOS 13

## Focused Protocol Gate

Command:

```text
CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-module-cache swift test --disable-sandbox --filter 'Wire(PreHandshakeCodec|Message)Tests'
```

Result: passed after review remediation, 22 tests executed, 0 failures, 0 skipped.

Coverage includes exact V1 bytes and typed round trips for hello, safe error, and disconnect; wider advertised intervals; Event-lane preflight; zero and future version precedence; mixed-invalid type, required-lane, and body cases; all known disallowed message types; unknown Control type; malformed, noncanonical, direct duplicate-key, and escaped-equivalent-key JSON; oversized frames; malformed and over-limit allowed payload models; tighter collection limits; immutable retention shape; compile-time Sendable checks; raw expected-version behavior; negotiated-session expected-version behavior; V1 handoff; and unregistered V2 session rejection.

## Full Swift Package Test Gate

Command:

```text
CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-module-cache swift test --disable-sandbox
```

Result: passed after review remediation, 256 tests executed, 0 failures, 5 skipped.

The five skips are existing Network.framework or Security trust tests whose required system services are unavailable in the restricted test sandbox. No assertion, command, or gate was weakened.

## Packaging and Consumer Boundary Gate

Command:

```text
Scripts/verify-package.sh
```

Result: passed.

- Process-lease structural and multi-image gates passed unchanged.
- Root/Core package parity passed.
- Strict iOS 16 SwiftPM build passed in Swift 5 language mode.
- Strict macOS 13 Core and NearWire builds passed.
- Canonical SwiftPM and CocoaPods same-module consumers compiled.
- SwiftPM and CocoaPods supported API inventories matched.
- `WirePreHandshakeCodec` and `WirePreHandshakeMessage` were inaccessible to normal SwiftPM and CocoaPods consumers.
- Supported SDK API contained no pre-handshake codec, typed result, admitted-message, or payload-protocol type.
- Wire sealing, mandatory TLS, raw-channel, CocoaPods same-module transport, and identity-lifecycle boundaries passed unchanged.
- iOS Simulator suite: 256 passed, 0 failed, 0 skipped on iPhone 17 Pro / iOS 26.4.
- macOS Core harness: 175 passed, 0 failed, 0 skipped.
- Production TLS 1.3 and ALPN integration tests executed and passed.

An earlier restricted-environment attempt stopped when `CoreSimulatorService` was unavailable. No assertion, command, or gate was weakened; the identical command passed after simulator-service access became available.

## CocoaPods Gate

Command:

```text
Scripts/verify-podspec.sh
```

Result: passed. CocoaPods `1.16.2` validated `NearWire (0.1.0)` and every Core, SDK, UI, and Performance path. The placeholder homepage warning is expected for the internal bootstrap metadata. AppIntents metadata notes are expected because NearWire has no AppIntents dependency.

An earlier restricted-environment attempt stopped at CocoaPods' `simctl list` prerequisite. The identical command passed after simulator-service access became available.

## Repository Gates

Commands:

```text
DO_NOT_TRACK=1 openspec validate --all --strict --no-interactive
Scripts/verify-boundaries.sh
Scripts/verify-structure.sh
Scripts/verify-english.sh
Scripts/verify-version.sh
Scripts/Tests/validation-tools.sh
swift format lint --recursive Package.swift Core SDK IntegrationTests/ProcessLeaseMultiImage Scripts/Fixtures
git diff --check
```

Results: passed.

- OpenSpec: 22 passed, 0 failed.
- Swift imports, Core SPI, secure construction, package, pod, and distribution boundaries passed.
- Repository structure passed.
- English CJK scan passed with semantic human review retained.
- Version `0.1.0` passed.
- Evidence-capture failure, simulator restoration, distribution mutation, and validation-tool suites passed.
- Swift formatting and whitespace checks passed.

## Supported API Inventory

The supported application API is unchanged. The pre-handshake codec and sealed typed result are `NearWireInternal` repository SPI in platform-neutral Core. Raw `WireMessage`, `WireMessageCodec`, and `WireMessagePayload` remain module-internal. No package product, target, dependency, pod subspec, entitlement, privacy declaration, or supported SDK signature changed.

## Residual Scope

This change adds no network operation, channel ownership, TLS action, discovery, process-lease claim, Viewer approval, timeout, task, timer, cancellation lifecycle, route, flow policy, event transfer, persistence, Keychain access, UI, public connect, or public disconnect. SDK session admission is the next sequential change after this change is archived and committed.
