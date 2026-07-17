## 1. Specification

- [x] 1.1 Define public composition, injected ownership, bounded Event presentation, and optional
      distribution behavior.
- [x] 1.2 Validate the OpenSpec proposal, design, deltas, and tasks in strict mode.

## 2. Package and public API

- [x] 2.1 Make the SwiftPM and CocoaPods UI distributions depend on Performance without changing the
      default SDK distribution.
- [x] 2.2 Add the complete panel and the two standalone public SwiftUI components with
      injected-instance replacement identity.

## 3. UI behavior

- [x] 3.1 Implement explicit Performance start/stop coordination, safe state and error presentation,
      and lifecycle cleanup.
- [x] 3.2 Implement independent Viewer-to-App Event observation and a bounded deterministic latest
      Event presentation.
- [x] 3.3 Compose connection, Performance, and latest Event controls into the complete panel with
      accessible, adaptive SwiftUI layout.

## 4. Coverage and documentation

- [x] 4.1 Add focused model, lifecycle, replacement, independent-subscription, bounded-summary, and
      rendering tests.
- [x] 4.2 Update representative public API smoke coverage and English/Chinese README usage.
- [x] 4.3 Refresh the temporary UIKit preview to render the complete panel without committing the
      temporary package or mock data.

## 5. Validation and review

- [x] 5.1 Run focused NearWireUI tests, complete Swift package tests, and Swift 5 warning-as-error
      builds for supported platforms.
- [x] 5.2 Validate SwiftPM/CocoaPods package metadata and the maintained Demo integration.
- [x] 5.3 Save exact validation evidence and record that independent review was stopped at the
      user's explicit direction before commit.
- [x] 5.4 Audit requirements against evidence and archive the completed change.
