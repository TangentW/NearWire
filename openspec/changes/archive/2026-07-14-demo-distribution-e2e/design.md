## Context

Core, the iOS SDK products, and the native Viewer are implemented and independently validated. The
root `Demo` directory still contains only a planning README, the root workspace references only the
Viewer project, and no maintained host application currently proves that the complete supported SDK
surface works as one product through both Swift Package Manager and CocoaPods.

The Demo is an internal integration application rather than another SDK layer. It must use only
supported public SDK APIs, preserve the instance-based ownership model, compile the same business
implementation through both package managers, and remain useful for manual iPhone-to-Viewer checks.
Core and SDK retain zero third-party runtime dependencies. The project is maintained manually with
Xcode 16 or later, Swift 5 language mode, and iOS 16 deployment compatibility.

Configured signing identities are not available to the autonomous implementation environment. The
user explicitly assigned the signed running-product entitlement assertion and stable-signer update
matrix to the terminal `release-hardening` change. This change can still build and test on an iOS
Simulator, produce unsigned generic-device artifacts, inspect embedded privacy resources, and attempt
Xcode's Organizer privacy-report action on an unsigned archive. If the host denies UI automation and
Xcode exposes no command-line equivalent, the exact limitation is evidence and the report remains a
mandatory `release-hardening` gate rather than being simulated or claimed.

## Goals / Non-Goals

**Goals:**

- Commit one manually maintained iOS Demo project and add its SwiftPM scheme to the root workspace.
- Compile one shared Demo source tree through SwiftPM and CocoaPods without a second behavior fork.
- Demonstrate connection UI injection, Codable uplink Events, Viewer control handling and causal
  replies, local buffer diagnostics, and explicit Performance monitor ownership.
- Keep application state, inputs, histories, Tasks, and displayed errors bounded and testable.
- Verify the host-owned Bonjour/local-network declarations and the actual privacy resources embedded
  by the base and Performance products.
- Add compact Demo-owned tests, Simulator build/test/launch evidence, package-manager consumer
  builds, and operator documentation.

**Non-Goals:**

- No new Core, SDK, wire, Viewer, Event, or Performance public behavior.
- No second transport, acknowledgement/RPC layer, server, persistence store, background execution,
  application lifecycle inference, or automatic connection.
- No duplicate CocoaPods-specific Demo implementation and no committed generated Pods project,
  workspace, lockfile, or build products.
- No project generator, new standalone shell harness, third-party Demo runtime dependency, nested
  `Package.swift`, or nested podspec.
- No claim that an unsigned Simulator/generic-device artifact proves installed-device permissions,
  configured signing, embedded signed entitlements, stable-Keychain access across updates, or the
  final real-device matrix.

## Decisions

### 1. One project contains two consumer targets over one source tree

`Demo/NearWireDemo.xcodeproj` will contain:

- `NearWireDemo`, the maintained SwiftPM application target linked to the root local package's
  `NearWire`, `NearWireUI`, and `NearWirePerformance` products;
- `NearWireDemoCocoaPods`, a build-only consumer target with the same source and resource membership,
  populated by a root-relative `Demo/Podfile` in a temporary copy during validation;
- `NearWireDemoTests`, a small unit target for the SwiftPM application module; and
- `NearWireDemoUITests`, a minimal launch/surface smoke target.

The root workspace references the committed project and builds `NearWireDemo`. The CocoaPods target
is built only from the workspace produced by `pod install` in a temporary root-layout snapshot, so
generated Pods state never mutates or enters the repository. That snapshot preserves `Demo`,
`Package.swift`, `Core`, `SDK`, `NearWire.podspec`, `VERSION`, and `LICENSE` under one temporary root;
therefore the committed Xcode local-package reference `..` still resolves exactly as it does in the
repository. The Podfile defaults to `File.expand_path("..", __dir__)`, may accept `NEARWIRE_ROOT`,
canonicalizes the selected path with `File.realpath`, and fails unless that exact root contains the
expected package manifest, podspec, version file, Core tree, and SDK tree. CocoaPods resolves the pod
against that temporary root, and evidence records its canonical identity.

Both application targets compile the exact same business `.swift` files. Source imports `NearWire`
unconditionally. Only the `NearWireDemo` target defines `NEARWIRE_DEMO_SEPARATE_MODULES`; that
condition guards only `import NearWireUI` and `import NearWirePerformance`. The CocoaPods target
never defines the condition because those optional sources compile into its aggregate `NearWire`
module. Every call site remains identical, and the parity audit rejects the condition outside import
declarations, package-manager-specific copies, or target-only business files. The Demo does not use
`SWIFT_PACKAGE`, because an Xcode App target consuming a local package does not receive that flag.

Alternative considered: two separate Demo projects or source trees. Rejected because they can drift
while appearing to prove parity. Alternative considered: committing generated Pods integration.
Rejected because it creates machine-generated noise and an additional maintenance owner.

### 2. The app owns one facade and one explicitly controlled monitor

The SwiftUI App root creates one `NearWire` instance and one `NearWirePerformanceMonitor` injected
with that exact instance. It injects the facade into `NearWireConnectionView`; construction starts no
connection or sampling. A MainActor application model owns finite state and at most two observation
Tasks: exactly one Event-loop Task and one Performance-state Task. It starts each observer
idempotently when the Demo surface is active.

Reusable Reset is the only explicit stream-restart mechanism. It increments the observation
generation, cancels and joins both exact predecessor Tasks, stops the exact Performance monitor,
awaits `NearWire.disconnect()`, clears presentation state, and only then installs one fresh Event
observer and one fresh Performance-state observer. It never calls `shutdown()`. Consequently an
overflow or other stream failure remains stopped with one fixed error until the operator selects
Reset; repeated resets are serialized and never overlap observer generations. Terminal teardown
performs the same generation invalidation, observer joins, monitor stop, and awaited disconnect,
then invokes synchronous terminal `NearWire.shutdown()` and clears presentation state without
claiming that hidden SDK lease or transport cleanup has been awaited.

The model depends on a small Demo-owned domain driver rather than exposing generic mocks throughout
the UI. The production driver's sequential Event loop keeps the exact public `NearWireEvent` local
while it evaluates one control, checks cancellation, applies the bounded Demo action, and calls
`NearWire.reply` against that source Event. Reset invalidates the observation generation, cancels the
loop, and joins it before disconnecting or clearing. The production driver otherwise delegates only
to public `NearWire` and `NearWirePerformance` APIs. Unit tests exercise the small domain evaluator
and application boundary; they do not emulate discovery, TLS, protocol, Viewer persistence, or
transport behavior already covered by production SDK/Viewer tests.

Alternative considered: using a global singleton for convenient SwiftUI access. Rejected because it
would contradict the SDK ownership contract and make target parity/lifecycle tests weaker.

### 3. Demo Event contracts are fixed, bounded, and ordinary SDK traffic

The App sends:

- `demo.message` as `.normal` with a UTF-8-bounded text payload; and
- `demo.counter` as `.keepLatest(key: "demo-counter")` with an integer state payload.

The App observes the public Event stream. It recognizes Viewer-to-App
`demo.control.set-banner`, decodes its Codable payload, and accepts a banner only when it is no more
than 512 UTF-8 bytes. The SDK has already applied its production Event byte and structural limits, so
the reference app does not duplicate the SDK's JSON parser or create another serialization budget.
A valid result updates the explicit Demo banner and uses `NearWire.reply` to send
`demo.control.result`. Unknown or invalid Viewer Events never trigger a reply or arbitrary action.
The presentation retains at most 50 safe event summaries and one fixed error. Pairing codes,
endpoints, arbitrary underlying error text, and hidden session implementation data are not logged.

Send results and diagnostics are labeled as local queue state only. The UI never calls them
delivered, received, acknowledged, or persisted.

Alternative considered: define a new control protocol in Core. Rejected because Demo commands are
application examples carried by the existing generic Event platform, not platform protocol.

### 4. Performance remains optional and explicit

The Demo exposes Start and Stop actions for the one monitor and observes its bounded latest-value
state. It does not start sampling at App launch, connection, view appearance, or scene transitions.
Performance failure displays only `NearWirePerformanceError.message`. Reset and model teardown stop
the monitor before facade shutdown. The same call sites compile through the SwiftPM product and the
CocoaPods Performance subspec.

### 5. Host declarations belong to the Demo target

Both application targets use the same Info.plist values:

- iOS 16 deployment;
- a host-specific `NSLocalNetworkUsageDescription`; and
- `NSBonjourServices` containing only `_nearwire._tcp` for NearWire.

No multicast, Keychain sharing, background mode, network extension, or other entitlement is added.
The two targets use distinct internal bundle identifiers but the same display name and business
behavior. The Demo adds no privacy manifest merely to duplicate dependency declarations.

### 6. Distribution validation builds real consumers and inspects products

Validation has four layers:

1. A compact unit suite checks only cheap Demo-owned logic: input byte limits, control mapping, and
   the bounded summary list. Production SDK and Viewer suites remain authoritative for queue,
   concurrency, transport, TLS, and causal-routing behavior.
2. The SwiftPM scheme builds/tests/launches on an iOS 16-compatible Simulator, and an unsigned generic
   iOS archive proves device compilation.
3. A temporary root-layout snapshot runs `pod install` with CocoaPods 1.16 or later and builds the
   CocoaPods target from the same source list. Its canonical package/pod root, source hashes, and
   original Git state are recorded; the committed project remains unchanged afterward.
4. Built App products are inspected for exact base and Performance privacy resources, host plist
   declarations, forbidden entitlements/dependencies, and source parity. Xcode Organizer is used to
   export an App Privacy Report from the unsigned generic archive when host UI automation is
   available. If macOS denies that access and Xcode provides no command-line export, the attempt and
   constituent product inspection are recorded without claiming a report; `release-hardening` must
   then export the report from the configured signed archive.

Existing production SDK/Viewer suites retain discovery, TLS, negotiation, flow-control,
bidirectional-wire, and SDK lifecycle authority. The Demo change reruns the focused production
bidirectional exchange regression but does not duplicate those tests or create a test transport.

### 7. Existing validation entry points are extended proportionately

The root workspace, structure, English, package-boundary, and bootstrap checks will include the Demo
where their existing responsibility applies. No new broad shell framework is added. Package-manager
build commands and privacy-report steps are recorded directly in OpenSpec evidence; a new script is
added only if an otherwise non-reproducible repeated operation cannot be expressed by the existing
checks.

## Risks / Trade-offs

- **[CocoaPods modifies an Xcode project during install]** → Run it only against a temporary
  root-layout snapshot, resolve both the project package and pod from that same copied root, compare
  source hashes and the original Git state afterward, and reject generated Pods state in Git.
- **[Conditional imports hide package-manager divergence]** → Compile both targets with warnings as
  errors and compare exact business source membership before accepting parity.
- **[Demo tests could overstate end-to-end coverage]** → Keep them limited to Demo-owned value
  mapping and presentation bounds, and retain production SDK/Viewer bidirectional exchange as the
  wire authority.
- **[High-rate Viewer controls grow UI state]** → Bound input bytes and retain at most 50 summaries;
  stream overflow becomes one fixed recoverable presentation error.
- **[Event observation outlives Reset]** → Invalidate its generation, cancel it, and join the exact
  loop before Reset disconnects or clears state.
- **[Performance collection adds global battery/display ownership]** → Keep start explicit, stop
  before shutdown, and use the existing monitor's tested ownership receipts.
- **[Privacy report generation is an Xcode UI operation]** → Save the exported report and exact
  archive identity when UI automation is available; separately automate manifest/product inspection.
  If macOS denies UI access and Xcode exposes no CLI equivalent, record both facts and retain report
  export as a mandatory `release-hardening` gate instead of inventing substitute evidence.
- **[Unsigned builds do not prove installed behavior]** → Label every unsigned result accurately and
  retain configured signing, entitlement, stable-signer, and real-device checks as mandatory final
  work.

## Migration Plan

This is additive. Add the project, sources, Podfile, tests, and documentation; then add the relative
workspace reference and extend existing validation checks. Rollback removes the Demo project and
workspace reference without changing Core, SDK, Viewer data, protocol, or public API.

## Open Questions

None before apply. Artifact review must confirm the target/source-membership scheme, CocoaPods
temporary-copy workflow, and privacy-report evidence are executable with the installed Xcode and
CocoaPods versions before production or test source is modified.
