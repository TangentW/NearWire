# NearWire Demo

The Demo is the maintained iOS reference application for NearWire. It uses one SwiftUI application implementation to demonstrate both supported package managers, the standard connection panel, bidirectional Codable Events, queue diagnostics, Viewer controls, and optional performance snapshots.

The Demo is intentionally small. The SDK and Viewer test suites own transport, TLS, queue, lifecycle, and concurrency coverage; this application proves that a consumer can integrate, build, launch, and use the public APIs.

## Requirements

- Xcode 16 or later
- iOS 16 or later
- Swift 5 language mode
- CocoaPods 1.16 or later for the CocoaPods path
- A Mac running the NearWire Viewer for an interactive connection

Configured device signing is not part of this Demo change. Simulator products and unsigned archives can be built without a development team. A later release-hardening step must validate a configured, signed device product.

## Run with Swift Package Manager

1. Open `NearWire.xcworkspace` at the repository root.
2. Select the `NearWireDemo` scheme and an iOS Simulator.
3. Build and run.

The committed Xcode project resolves the root package through the relative `..` reference and links `NearWire`, `NearWireUI`, and `NearWirePerformance`. No dependency generation is required.

The command-line equivalent is:

```sh
xcodebuild \
  -workspace NearWire.xcworkspace \
  -scheme NearWireDemo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Run with CocoaPods

The `NearWireDemoCocoaPods` target compiles the same Swift files and asset catalog. CocoaPods combines the UI and Performance subspecs into the single `NearWire` module, while SwiftPM exposes their separate modules. The only conditional code in the Demo is the additional SwiftPM import statements; behavior and public call sites are shared.

`pod install` modifies the client project and creates a generated workspace, Pods directory, and lockfile. Run this path in a throwaway checkout or a temporary root-layout copy, not in a working tree that contains changes you want to preserve:

```sh
pod install --project-directory=Demo --no-repo-update
xcodebuild \
  -workspace Demo/NearWireDemo.xcworkspace \
  -scheme NearWireDemoCocoaPods \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The Podfile resolves NearWire from the canonical repository root by default. `NEARWIRE_ROOT` may point to another complete NearWire root, but the selected directory must contain `Package.swift`, `NearWire.podspec`, `VERSION`, `LICENSE`, `Core`, and `SDK`.

Do not commit `Demo/Pods`, `Demo/Podfile.lock`, or the generated `Demo/NearWireDemo.xcworkspace`.

## Pair with the Viewer

1. Open the NearWire macOS Viewer. It starts listening and displays a pairing code.
2. Launch the Demo on the iPhone or Simulator.
3. Enter the Viewer code in the Connection panel and select Connect.
4. Accept the device in the Viewer if manual approval is enabled.

The pairing code selects the nearby Bonjour service; it is public discovery data, not a password. NearWire uses mandatory TLS for transport encryption, but the current self-signed Viewer identity is not authenticated by the pairing code.

The host application declares `_nearwire._tcp` in `NSBonjourServices` and includes `NSLocalNetworkUsageDescription`. iOS may show the local-network permission prompt on first use. Denying it prevents discovery until the permission is restored in Settings.

## Exercise Events and controls

- **Send Message** enqueues a normal `demo.message` Event containing a Codable message value.
- **Increment and Send** enqueues `demo.counter` with keep-latest key `demo-counter`, so a pending older counter may be replaced before transmission.
- **Refresh** reads the SDK's local in-memory queue diagnostics. These values describe local buffering only and do not prove that the Viewer received an Event.
- The Viewer can send `demo.control.set-banner` with JSON content shaped as `{ "banner": "New text" }`.
- A valid Viewer-to-App banner control replaces the current banner and queues a causal `demo.control.result` reply to that exact source Event.

Message and banner text is limited to 512 UTF-8 bytes. The control summary keeps the newest 50 entries and the UI shows the newest five. Unknown, wrong-direction, malformed, empty, or oversized controls are summarized or ignored without being executed.

NearWire Events are a local real-time debugging channel. The Demo does not claim acknowledgement, remote delivery, exactly-once processing, background persistence, or recovery after process termination.

## Background and foreground recovery

The Demo forwards its SwiftUI scene lifecycle to the SDK. Entering the background asks NearWire to suspend and clean up the current route; returning active asks it to discover the Viewer and establish a fresh TLS session from the in-memory connection intent. Initial connection is still explicit, and selecting Disconnect or Reset clears that intent, so foreground activation cannot connect by itself afterward.

While backgrounded, the Connection panel marks recovery as Paused. After returning active, it progresses through Reconnecting (with the attempt number) to Connected; a permanent failure or exhausted retry budget ends at Disconnected and requires a new explicit pairing-code connection.

The Demo also enables six bounded recovery attempts, beginning after 500 milliseconds and capping the delay at four seconds. This covers a route failure that iOS reports only after the App has already returned active. The budget is finite and stops after a permanent failure, exhaustion, manual disconnect, or process termination.

iOS may suspend the process and terminate its local peer-to-peer route. NearWire does not keep the Demo online in background, request background execution, or persist the pairing code. Recovery starts only while the same App process is alive and runnable. Events still eligible in the bounded local queue may drain on the fresh session; bytes already accepted by the old transport are not replayed, and local enqueue still does not prove Viewer receipt.

## Exercise performance snapshots

Select **Start Performance** to start the optional `NearWirePerformanceMonitor`. It publishes the built-in performance snapshot Event through the same bounded keep-latest path used by ordinary NearWire Events. Open the selected device's Performance page in the Viewer to inspect the resulting series. Select **Stop Performance** when sampling is no longer needed.

Sampling is explicit and remains off at launch. The Demo adds no timer, collector, retry loop, alternate queue, or transport of its own.

## Reset and cleanup

**Reset Demo** asks for confirmation, then cancels and joins the Demo observation tasks, stops performance sampling, disconnects the reusable NearWire session, clears presentation state, and starts fresh observation streams. It does not persist Event content, pairing data, control history, or diagnostics.

To remove CocoaPods output from a throwaway checkout, delete the generated `Demo/Pods`, `Demo/Podfile.lock`, and `Demo/NearWireDemo.xcworkspace`, then restore the generated CocoaPods edits to `Demo/NearWireDemo.xcodeproj` by discarding that throwaway checkout.

## Privacy resources

Both distribution paths embed the SDK privacy declaration for the private installation identifier. Enabling Performance also embeds its separate Performance Data declaration. Neither manifest enables tracking. The Demo does not add clipboard, log, export, share, or persistence surfaces for Event content or pairing data.

These declarations and unsigned Simulator builds do not replace the final Xcode privacy report and configured-signing checks required before release.
