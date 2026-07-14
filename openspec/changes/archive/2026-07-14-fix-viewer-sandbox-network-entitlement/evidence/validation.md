# Implementation Validation

Date: 2026-07-15 (Asia/Shanghai)

## Focused Signed Entitlement Regression

```sh
xcodebuild test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination platform=macOS \
  -derivedDataPath /tmp/nearwire-sandbox-entitlement-focused \
  DEVELOPMENT_TEAM=9PA6Z533LV \
  CODE_SIGN_STYLE=Automatic \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements \
  -quiet
```

Result: exit status 0. The signed process exposed App Sandbox, network-client, and network-server
entitlements while the test continued to reject multicast, Keychain-sharing, and application-group
capabilities.

## Complete Signed Viewer Test Suite

```sh
xcodebuild test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination platform=macOS \
  -derivedDataPath /tmp/nearwire-sandbox-entitlement-full \
  DEVELOPMENT_TEAM=9PA6Z533LV \
  CODE_SIGN_STYLE=Automatic \
  OTHER_SWIFT_FLAGS=-strict-concurrency=complete \
  -quiet
```

Result: exit status 0. The xcresult summary reported 398 total tests, 396 passed, 2 skipped,
0 failed, and 0 expected failures. Xcode emitted only existing SDK/toolchain warnings about signed
XCTest support binaries and macOS 13 test-target linkage to XCTest built for macOS 14.

## Standalone Signed Viewer Build and Packaging Audit

```sh
xcodebuild build \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath /tmp/nearwire-sandbox-entitlement-build \
  DEVELOPMENT_TEAM=9PA6Z533LV \
  CODE_SIGN_STYLE=Automatic \
  -quiet

codesign -d --entitlements - \
  /tmp/nearwire-sandbox-entitlement-build/Build/Products/Debug/NearWire.app

plutil -p \
  /tmp/nearwire-sandbox-entitlement-build/Build/Products/Debug/NearWire.app/Contents/Info.plist

plutil -lint \
  /tmp/nearwire-sandbox-entitlement-build/Build/Products/Debug/NearWire.app/Contents/Resources/PrivacyInfo.xcprivacy
```

Results:

- build exit status 0;
- signed product contains App Sandbox, network-client, network-server, and the expected Debug-only
  `get-task-allow` entitlement, with no multicast, Keychain-sharing, application-group, or
  background-service entitlement;
- Info.plist contains `_nearwire._tcp`, the required local-network usage description, bundle ID
  `com.nearwire.viewer`, and macOS 13 deployment metadata;
- packaged privacy manifest is valid.

The development team was supplied only as a command-line build setting. No project signing change
is part of this delivery.

## Static and OpenSpec Checks

```sh
plutil -lint Viewer/NearWireViewer/Resources/NearWireViewer.entitlements
DO_NOT_TRACK=1 openspec validate fix-viewer-sandbox-network-entitlement --strict --no-interactive
git diff --check
```

Result: all commands exited 0.
