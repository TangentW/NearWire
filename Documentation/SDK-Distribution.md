# SDK Distribution

## Supported Environment

- Xcode 16 or later
- iOS 16 or later
- Swift 5 language mode
- Swift Package Manager or CocoaPods

Swift 5 compatibility means `SWIFT_VERSION = 5.0` with the modern compiler bundled in Xcode 16. NearWire uses async/await, actor isolation, AsyncSequence, and Sendable; it does not support legacy compilers that predate Swift concurrency.

## Swift Package Manager

The root package exposes three supported SDK products:

- `NearWire`
- `NearWireUI`
- `NearWirePerformance`

`NearWireCore` is present for the local Viewer build and repository tests. Its declarations use the `NearWireInternal` Swift SPI so CocoaPods can compile Core and SDK sources into one module without making Core values visible to a normal `import NearWire`. Repository-owned targets opt into that SPI explicitly. It is an internal product and is not covered by consumer API compatibility guarantees.

Supported SDK signatures never expose a type that exists only in NearWireCore, NearWireTransport, or NearWireFlowControl. Public event, configuration, reconnection-policy, connection-status, and result models belong to `NearWire`, `NearWireUI`, or `NearWirePerformance` and convert to internal models behind the supported module boundary. SwiftPM and CocoaPods compile the same disconnect, suspend, resume, and status APIs.

`NearWireBuiltins` is a separate narrow SPI on the supported SDK module. It lets repository-owned optional modules, such as `NearWirePerformance`, enqueue reserved `nearwire.*` events through the same facade and queue. It is not an application API and does not grant access to the broader `NearWireInternal` implementation SPI.

The root package intentionally has no external package dependencies. Viewer-only dependencies are managed by the Viewer Xcode project and are never resolved by SDK consumers.

The primary SDK target explicitly links Apple's `Security.framework` for its private installation-identity Keychain implementation. Security types do not appear in supported signatures, and consumers add no host-facing dependency or configuration.

## CocoaPods

The root podspec defines these subspecs:

- `NearWire/Core`: Internal shared implementation.
- `NearWire/SDK`: Primary SDK and the default subspec.
- `NearWire/UI`: Optional connection UI.
- `NearWire/Performance`: Optional built-in performance collection.

The default integration is:

```ruby
pod "NearWire"
```

Optional products are selected explicitly:

```ruby
pod "NearWire/UI"
pod "NearWire/Performance"
```

The CocoaPods module name is fixed as `NearWire`. The podspec does not force static-framework linkage; CocoaPods and the consuming application retain the default linkage selection. The SDK subspec links only Apple's `Security.framework` for the same private Keychain implementation as SwiftPM. NearWire declares no third-party runtime framework, weak framework, library, module map, prefix header, compiler flag, consumer build setting, or script hook. Its pod target build settings are restricted to module generation, complete Swift concurrency checking, and warnings as errors. Any expansion requires a reviewed OpenSpec contract change.

The final internal Specs repository, project homepage, and Git source URL will be selected during release engineering. The bootstrap podspec uses reserved, non-resolving `example.invalid` HTTPS locations, so an accidental pre-release integration cannot fetch code from an unrelated namespace. The podspec cannot be published until release engineering replaces both values with authorized internal locations.

Repository validation runs `pod lib lint` in private-spec mode because NearWire is an internal product. This preserves local source compilation, subspec, dependency, and import validation while treating the expected unreachable placeholder homepage result as public-release-only metadata. Compiler, import, concurrency, and other non-public validation warnings remain failures. Private lint does not prove remote ownership or availability; release hardening must validate the authorized replacement locations.
