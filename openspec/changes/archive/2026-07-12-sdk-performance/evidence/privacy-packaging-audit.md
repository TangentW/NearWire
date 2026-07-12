# Privacy and Packaging Audit

Date: 2026-07-12

## Complete-envelope decision

The base SDK creates a Keychain-backed installation UUID, sends it as the App `WireHello.installationID`, and uses the admitted App route for performance Events. The Viewer can therefore correlate performance measurements with an App installation. The package-level report declares:

- base `NearWire`: Device ID, App functionality, linked true, tracking false;
- optional `NearWirePerformance`: Performance Data, App functionality, linked true, tracking false;
- both components: omit tracking domains and Required Reason API keys because tracking is false and no current covered API is used.

The executable fixture `SDK/Tests/NearWirePerformanceConsumer/InstallationCorrelatedEnvelope.json` binds a V1 performance body to an App source identity and is decoded by the focused tests.

## Source and built artifacts

| Artifact | SHA-256 |
| --- | --- |
| Base source manifest | `c4c35a46ffb411b2ef74002a52a714c0f0988e0c80a6a7e53c2ec1c609be13d0` |
| Built SwiftPM base manifest | `c4c35a46ffb411b2ef74002a52a714c0f0988e0c80a6a7e53c2ec1c609be13d0` |
| Performance source manifest | `3149883c808495f206f03caa4560021b17051775becf57d58d86f0fe6722d79a` |
| Built SwiftPM Performance manifest | `3149883c808495f206f03caa4560021b17051775becf57d58d86f0fe6722d79a` |
| `Package.swift` | `93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1` |
| `NearWire.podspec` | `4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33` |

Canonical run `20260712T101542Z-40669` proves both final built manifests are byte-identical to their owners, valid plists, and present in separate target bundles. The focused XCTest parses each source manifest structurally and verifies its exact owned data type, purpose, linked value, tracking value, and omitted unused keys. Distribution checks prove the default SDK owns only its base manifest while the optional Performance target/subspec adds its separate manifest and UIKit/QuartzCore implementation. Source review confirms the collector uses `ContinuousClock` rather than directly calling the covered system-uptime APIs; this change intentionally does not maintain a second source-text or symbol-scanning test framework.

Validation-script hashes for the final run are:

- `Scripts/verify-package.sh`: `e0ef8c53c4b7310922b9581af094359a342d6e65bd6d6e548739c03a2ac4f875`
- `Scripts/check-swift-boundaries.rb`: `0aec4d65c96d9b9720beb1a762d72e2696c248f85771ef4648608c294cc5c42f`

## Current Apple policy review

Apple's current documentation says that a privacy manifest records collected data and Required Reason API categories, that Swift packages must explicitly declare `PrivacyInfo.xcprivacy` as a resource, that performance diagnostics and device-level identifiers have dedicated data categories, and that linkage includes association through a device or other identity. Apple's Required Reason documentation lists direct `systemUptime` and `mach_absolute_time()` access under the system boot-time category. Sources reviewed:

- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest
- https://developer.apple.com/app-store/app-privacy-details/

This change produces libraries, not a host App archive. The package-level report above is therefore the final SDK artifact audit. The aggregate Xcode App privacy report remains an explicit `demo-distribution-e2e` and `release-hardening` gate, where it will be generated from the maintained host App rather than a temporary validation-only project.
