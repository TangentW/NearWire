# Spec-to-Evidence Audit

Status: complete against canonical run `20260712T101542Z-40669` and the Round 4 zero-finding review set.

## Public API and dependency boundary

The supported public Performance families are `NearWirePerformanceConfiguration`, `NearWirePerformanceError` with closed `Code`, `NearWirePerformanceMonitorState`, and actor `NearWirePerformanceMonitor`. Small SwiftPM and CocoaPods consumers compile that documented use, and the SDK-only fixture cannot name the optional monitor. Core and SDK add no third-party runtime dependency; UIKit and QuartzCore remain optional Performance-only links.

Evidence: small consumer compilation and packaged-resource checks in `raw/08-swift-package.log`, CocoaPods validation in `raw/09-cocoapods.log`, and import/dependency isolation in `raw/07-boundaries.log`.

## Lifecycle, retention, and resource bounds

Explicitly gated tests cover pre-lease cancellation, shared concurrent start, cancellation of a shared attempt, cancellation after activation authorization, idempotent running start, exact-instance contention, stop during setup, explicit and failure cleanup, Stopped override, late failure rejection, deinitialization, and newest-one subscriber behavior. A 1,000-cycle fake-resource test proves exact lease/collector cleanup. iOS display and battery behavior remains smoke-tested rather than represented as a deterministic live UIKit counter.

Evidence: focused 51-test result in `final-validation.md` and the 517-passed iOS simulator suite in `raw/08-swift-package.log`.

## Metric and snapshot parity

Tests cover interval boundaries and half-up clamps; initial/recovered/regressing/nonfinite CPU baselines; zero, 60, 120, delayed, invalid, and reset display cadence; managed ownership conflicts and unmanaged iOS behavior; present zero, temporary, permission-denied, disabled, and unsupported values; exact sorted unique metric inventory; unknown battery/thermal decoding; Core JSON round trip; terminal-drop saturation; and installation-correlated envelope decoding. The live iOS smoke test invokes process CPU, physical footprint, display-link, battery, thermal, and low-power paths without fragile device-value assertions. macOS start is unsupported before resources.

Evidence: focused tests, iOS simulator coverage in `raw/08-swift-package.log`, and `privacy-packaging-audit.md`.

## Delivery and overhead

Each run turn submits the exact reserved type with the exact keep-latest key through the ordinary NearWire queue. A 10,000-admission stress test proves one retained Event, 9,999 coalesced Events, and zero overflow, expiry, or routing drops. A separate no-sleep 10,000-projection benchmark proves exactly 10,000 completed projections; timing is diagnostic. The 1,000-cycle test returns the lease and clock-waiter counts to zero.

Evidence: focused 51-test result and complete SwiftPM/Core/TLS results in `raw/08-swift-package.log`.

## Documentation and privacy

README, distribution, public API, Event model, architecture, roadmap, and the dedicated Performance guide document installation, lifecycle/reentrancy, failure cleanup, units, sources, CPU recovery, unavailable meanings, battery ownership, callback-FPS limitations, unsupported fields, queue behavior, overhead, platform fallback, and complete-envelope privacy ownership. Manifest semantics, packaged resources, and current Apple policy are audited in `privacy-packaging-audit.md`; the host-App aggregate report is preserved for the real Demo/release archive.

## Audit result

Every active requirement and scenario maps to current implementation, focused or canonical automated evidence, packaging evidence, or the explicitly assigned later host-App aggregate privacy-report gate. Round 4 architecture/API, correctness/testing, and security/performance/documentation reviews each report zero unresolved actionable findings.
