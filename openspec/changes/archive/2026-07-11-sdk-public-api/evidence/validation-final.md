# SDK Public API Final Validation

## Run Identity

- Captured: `2026-07-11T06:43:20Z`
- Base commit: `c6f45155c0e473a25d7fa43b40f5f142cfb72621`
- Xcode: `26.6 (17F113)`
- Swift: `6.3.3`, compiled in Swift 5 language mode
- CocoaPods: `1.16.2`
- OpenSpec: `1.2.0`
- Required compatibility targets: iOS 16 and macOS 13

## Full Package Gate

Command:

```text
./Scripts/verify-package.sh
```

Result: passed.

Verified evidence:

- Core package fixture parity passed.
- Strict iOS 16 SwiftPM build passed with Swift 5 language mode.
- The canonical SDK and built-in SPI consumers compiled against the iOS SwiftPM product.
- Strict macOS 13 builds passed for every Core target and the NearWire SDK target.
- The supported SDK API inventory exposed no Core, flow-control, transport, Network.framework, or Security.framework implementation type.
- The canonical consumers compiled against the CocoaPods same-module source layout.
- iOS SwiftPM and iOS CocoaPods non-SPI API inventories were identical.
- Wire payload sealing, mandatory TLS, raw-channel construction, same-module transport, and identity-lifecycle boundaries passed.
- iOS Simulator `NearWire-Package` tests: 190 passed, 0 failed, 0 skipped on iPhone 17 Pro / iOS 26.4 Simulator.
- macOS Core harness tests: 158 passed, 0 failed, 0 skipped.
- Production TLS 1.3, ALPN, trust evaluation, listener serialization, downgrade rejection, and certificate-path tests executed rather than skipping.

## CocoaPods Gate

Command:

```text
./Scripts/verify-podspec.sh
```

Result: passed.

`NearWire (0.1.0)` and its `PublicAPI` test specification passed validation. CocoaPods emitted the expected warning for the reserved bootstrap homepage `https://example.invalid/nearwire` and informational AppIntents metadata messages because NearWire does not depend on AppIntents. There were no build or test errors.

## Repository Gates

Commands:

```text
DO_NOT_TRACK=1 openspec validate sdk-public-api --strict --no-interactive
./Scripts/verify-boundaries.sh
./Scripts/verify-english.sh
./Scripts/Tests/validation-tools.sh
git diff --check
```

Results: passed.

- OpenSpec change structure and delta specifications are valid.
- Swift module, Core SPI, secure construction, package, pod, and exact distribution manifest boundaries passed.
- CJK scan passed, and independent documentation review reported zero findings.
- Evidence-failure, simulator-restoration, distribution-mutation, and validation-tool regressions passed.
- No whitespace errors remain.

## Public API Inventory

Supported `NearWire` facade:

- Side-effect-free instance initialization with immutable configuration.
- `configuration`, `currentState`, `states`, and `events`.
- Generic Codable `send` and causal `reply`.
- Buffer diagnostics and explicit clearing.
- Idempotent terminal shutdown.
- Narrow repository-owned `NearWireBuiltins` SPI for reserved platform events.

Supported NearWire-owned values:

- Event content, priority, direction, TTL, send policy, and event options.
- Buffer and facade configuration.
- State, session metadata, received event, send result, buffer statistics, buffer diagnostics, and clear result.
- Stable safe `NearWireError` and error codes.

No supported signature names `NearWireCore`, `NearWireFlowControl`, `NearWireTransport`, Network.framework, Security.framework, or Viewer-only declarations.

## Review Result

Five remediation rounds were recorded. The final fresh architecture/API, correctness/testing, and security/performance/distribution/documentation reviews each reported zero unresolved findings.

## Residual Scope

This change intentionally does not implement discovery, pairing admission, active-session ownership, rate scheduling, reconnection, Viewer identity lifecycle, UI, performance collection, Viewer persistence, or Demo integration. Those remain named future changes and are not required for this archive.

