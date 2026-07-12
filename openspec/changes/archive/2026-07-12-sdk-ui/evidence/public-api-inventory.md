# Public API Inventory

Date: 2026-07-12

## SwiftPM NearWireUI Product

The supported declaration delta is exactly:

```swift
public struct NearWireConnectionView: SwiftUI.View {
  public init(nearWire: NearWire.NearWire)
  public var body: some SwiftUI.View { get }
}

public struct NearWireConnectionStatusView: SwiftUI.View {
  public init(status: NearWire.NearWireConnectionStatus)
  public var body: some SwiftUI.View { get }
}
```

No model, controller seam, operation phase/token/coordinator, action or status presentation, pairing input, Task, route, endpoint, certificate, lease, transport, Core, or Viewer type is public or SPI.

## Distribution Evidence

`Scripts/check-sdk-ui-structure.rb` rejects any third public type or initializer/body count change. `Scripts/verify-package.sh` additionally:

- compiles an external SwiftPM consumer importing `NearWire` and `NearWireUI`;
- proves an external SwiftPM consumer cannot name internal UI types;
- proves the CocoaPods SDK-only aggregate cannot name either view;
- builds the CocoaPods UI aggregate from the exact Core, SDK, and UI source globs;
- compiles a UI-subspec-style external consumer importing `NearWire`;
- proves that consumer cannot name internal UI types;
- confirms the aggregate retains the complete SDK public inventory and adds both expected views; and
- source-audits the exact two-type, two-initializer, two-body delta.

All of these gates passed under Swift 5 language mode, complete concurrency checking, warnings as errors, iOS 16, and the iOS SDK. The final iOS simulator suite also passed with 470 total tests, 466 passed, four existing skips, and zero failures.
