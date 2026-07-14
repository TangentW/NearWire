## Why

NearWire now has a complete SDK and Viewer, but the repository still lacks the maintained iOS host
application that proves a real consumer can integrate the public products without implementation
imports or duplicated package-manager-specific business code. This change closes that product and
distribution gap before final configured-signing hardening.

## What Changes

- Add one manually maintained SwiftUI iOS 16 Demo project under `Demo` and add its Swift Package
  scheme to the root workspace with repository-relative references.
- Compile one shared Demo application implementation through both the root Swift Package products
  and a CocoaPods consumer target; do not maintain a second Demo behavior implementation.
- Exercise one injected `NearWire` instance, `NearWireUI`, ordinary and keep-latest Codable uplink
  Events, bounded Viewer control handling and causal replies, buffer diagnostics, and explicit
  `NearWirePerformance` start/stop behavior.
- Add a small Demo validation suite plus an iOS Simulator launch smoke test and public-boundary
  distribution builds. Reuse production SDK and Viewer protocol coverage rather than retesting the
  transport or creating a test-only product protocol inside the reference application.
- Supply the host-owned local-network and Bonjour declarations and verify that base SDK and optional
  Performance privacy resources are present in the built host application through both distribution
  paths.
- Document how an internal developer builds, runs, pairs, sends Events, handles Viewer controls, and
  enables performance sampling.
- Keep configured Apple signing, the signed running-product entitlement assertion, stable-signer
  update validation, and the final real-device release matrix in the terminal `release-hardening`
  change; this change does not claim those checks passed.

## Capabilities

### New Capabilities

- `demo-integration-application`: Defines the maintained iOS Demo's ownership, public API usage,
  bounded lifecycle, user-visible integration flows, host declarations, and testable behavior.

### Modified Capabilities

- `repository-structure`: Completes the previously deferred Demo project and root-workspace
  composition while retaining manual project maintenance and one Demo implementation.
- `sdk-distribution`: Requires the same maintained Demo business sources to compile through SwiftPM
  and CocoaPods with equivalent optional UI, Performance, privacy-resource, and public-API behavior.

## Impact

- Adds `Demo/NearWireDemo.xcodeproj`, the shared Demo source and tests, one CocoaPods consumer target
  and Podfile, and Demo integration documentation.
- Updates `NearWire.xcworkspace` to reference the Demo project alongside Viewer.
- Adds no Core or SDK runtime dependency, no project generator, no nested package manifest or
  podspec, and no new supported SDK API.
- Validation will use Xcode 16 or later, iOS 16 compatibility, Swift 5 language mode, CocoaPods 1.16
  or later, unsigned Simulator/device-generic builds where appropriate, and existing root package and
  Viewer regression gates.
