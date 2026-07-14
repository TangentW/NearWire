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

`NearWireUI` depends on `NearWire` and adds exactly two supported SwiftUI views: `NearWireConnectionView` and `NearWireConnectionStatusView`. It has no resource bundle or third-party dependency. Applications must add both products to the consuming target and inject their own configured `NearWire` instance.

`NearWirePerformance` depends on `NearWire` and the internal Core schema. It adds exactly the supported configuration, error, lifecycle-state, and monitor families; snapshot values and collector seams remain internal. Its UIKit and QuartzCore collectors compile only in the optional product. See [SDK-Performance.md](SDK-Performance.md).

`NearWireCore` is present for the local Viewer build and repository tests. Its declarations use the `NearWireInternal` Swift SPI so CocoaPods can compile Core and SDK sources into one module without making Core values visible to a normal `import NearWire`. Repository-owned targets opt into that SPI explicitly. It is an internal product and is not covered by consumer API compatibility guarantees.

Supported SDK signatures never expose a type that exists only in NearWireCore, NearWireTransport, or NearWireFlowControl. Public event, configuration, reconnection-policy, connection-status, and result models belong to `NearWire`, `NearWireUI`, or `NearWirePerformance` and convert to internal models behind the supported module boundary. SwiftPM and CocoaPods compile the same disconnect, suspend, resume, and status APIs.

`NearWireBuiltins` is a separate narrow SPI on the supported SDK module. It lets repository-owned optional modules, such as `NearWirePerformance`, enqueue reserved `nearwire.*` events through the same facade and queue. It is not an application API and does not grant access to the broader `NearWireInternal` implementation SPI.

The root package intentionally has no external package dependencies. Viewer-only dependencies are managed by the Viewer Xcode project and are never resolved by SDK consumers.

The primary SDK target explicitly links Apple's `Security.framework` for its private installation-identity Keychain implementation. Security types do not appear in supported signatures, and consumers add no host-facing dependency or configuration.

SwiftPM processes one privacy manifest in each collecting target. NearWire owns the linked Device ID declaration for its installation UUID. NearWirePerformance owns the linked Performance Data declaration and is absent when the optional product is omitted. Both use App functionality and disable tracking.

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

The default `NearWire` or explicit `NearWire/SDK` installation does not compile the SwiftUI sources or expose UI declarations. `NearWire/UI` compiles Core, SDK, and UI sources into the CocoaPods `NearWire` module and provides the same two supported views as the separate SwiftPM NearWireUI product.

The default SDK subspec packages `NearWireSDKPrivacy.bundle` for Device ID disclosure. `NearWire/Performance` additionally packages `NearWirePerformancePrivacy.bundle`; omitting Performance omits that source, UIKit/QuartzCore linkage, public API delta, and privacy bundle. The two bundle names are distinct so CocoaPods aggregation cannot overwrite either manifest.

The CocoaPods module name is fixed as `NearWire`. The podspec does not force static-framework linkage; CocoaPods and the consuming application retain the default linkage selection. The SDK subspec links only Apple's `Security.framework` for the same private Keychain implementation as SwiftPM. NearWire declares no third-party runtime framework, weak framework, library, module map, prefix header, compiler flag, consumer build setting, or script hook. Its pod target build settings are restricted to module generation, complete Swift concurrency checking, and warnings as errors. Any expansion requires a reviewed OpenSpec contract change.

The podspec identifies the public `TangentW/NearWire` GitHub repository as both its project homepage and Git source. Release tags use the same semantic version as the root `VERSION` file. The repository and distributed SDK are available under the root MIT License.

Repository validation runs `pod lib lint` in private-spec mode so local source, subspec, dependency, import, and license metadata can be validated before a version tag is published. Compiler, import, concurrency, and packaging warnings remain failures. A successful local lint does not prove that a matching remote tag exists; release validation must verify the repository and tag before publishing the podspec.
