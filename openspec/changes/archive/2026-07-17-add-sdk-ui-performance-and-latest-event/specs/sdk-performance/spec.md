## MODIFIED Requirements

### Requirement: Performance overhead and packaging remain optional and measured

NearWirePerformance SHALL add no runtime dependency, entitlement, persistence, MetricKit subscriber,
or framework import to Core or NearWire. NearWireUI MAY depend on NearWirePerformance solely to
expose host-injected explicit controls and SHALL NOT create or automatically start a monitor.
Privacy ownership SHALL follow collection source. The base NearWire target/subspec SHALL package its
own valid `PrivacyInfo.xcprivacy` declaring Device ID for App functionality, user-linked true,
tracking false, and no tracking domains because it creates, persists, transmits, and enables Viewer
correlation of the installation UUID. The optional Performance target/subspec SHALL package a
separate valid manifest declaring Performance Data for App functionality, user-linked true, tracking
false, and no tracking domains. Linkage SHALL be assessed over the complete transmitted envelope and
Viewer correlation behavior.

SwiftPM SHALL process each manifest only in its owning target. CocoaPods SHALL package separate
uniquely named SDK and Performance privacy resource bundles, with the Performance bundle remaining
optional unless the consumer selects Performance or UI. Each manifest SHALL declare exactly the
Required Reason API categories used by its owning executable. The collector SHALL use
`ContinuousClock` for relative time and SHALL NOT directly call `mach_absolute_time()` or
`ProcessInfo.systemUptime`; any future covered API SHALL update the owning manifest before release.

SwiftPM and CocoaPods Performance SHALL compile the supported API in Swift 5 language mode for iOS
16. The package SHALL also compile on macOS 13 with unsupported start semantics. Evidence SHALL
validate manifest content in focused tests, plist syntax, packaged resource presence and
default-SDK absence, and current Apple policy. Packaging validation SHALL use small real-consumer
smoke checks and SHALL NOT duplicate runtime XCTest behavior with source-text, symbol, exact
declaration-tree, or mutation-test machinery. Because this change produces libraries rather than a
host App archive, the aggregate Xcode App privacy report SHALL remain an explicit
`demo-distribution-e2e` and `release-hardening` gate instead of being fabricated from a temporary
App. Evidence SHALL also record exact inactive/running resource counts, repeated teardown stress,
deterministic collector work counts, a non-sleeping 10,000-turn microbenchmark, and iOS platform
smoke coverage; timing SHALL be reported and SHALL NOT replace exact correctness bounds.

#### Scenario: Consumer omits Performance

- **WHEN** an App imports only NearWire or installs the default CocoaPods subspec
- **THEN** no Performance public type, UIKit/QuartzCore collector source, Performance privacy
  resource bundle, display link, battery monitoring, sampling Task, or additional dependency is
  required
- **AND** the base SDK still packages its correctly owned Device ID privacy manifest

#### Scenario: Consumer includes Performance

- **WHEN** SwiftPM or CocoaPods integrates the optional Performance module directly or through
  NearWireUI
- **THEN** its packaged artifact contains one valid Performance privacy manifest with the approved
  collection declaration
- **AND** the declaration reports installation linkage while tracking remains false
- **AND** the base NearWire artifact contains its separate Device ID declaration

#### Scenario: Overhead evidence runs

- **WHEN** the deterministic benchmark and resource probes complete
- **THEN** their exact work/resource counts meet the specified bounds
- **AND** measured timing is recorded without being treated as a universal device threshold
