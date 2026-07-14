# Built Products and Privacy Evidence

## Result

Task 6.3 passed under the amended host-UI limitation on 2026-07-14.

The real SwiftPM unsigned archive App and CocoaPods Simulator App contain the same host declarations and the correct distribution-specific privacy bundles. Every embedded manifest is byte-identical to its owning SDK source manifest and passes `plutil -lint`.

## Product identities

| Product | Bundle identifier | Version/build | Minimum iOS | Bonjour service |
|---|---|---|---|---|
| SwiftPM unsigned archive | `com.nearwire.demo.spm` | `0.1.0` / `1` | `16.0` | `_nearwire._tcp` |
| CocoaPods Simulator App | `com.nearwire.demo.cocoapods` | `0.1.0` / `1` | `16.0` | `_nearwire._tcp` |

The archive contains no `_CodeSignature`, `embedded.mobileprovision`, or entitlements file, and `codesign` reports `code object is not signed at all`. Its archive metadata records empty `SigningIdentity` and `Team`. The CocoaPods product has no host entitlements or provisioning profile. Link inspection shows only Apple system frameworks and static NearWire composition; no third-party runtime framework is embedded.

## Privacy bundles

SwiftPM archive:

```text
NearWire_NearWire.bundle/PrivacyInfo.xcprivacy
NearWire_NearWirePerformance.bundle/PrivacyInfo.xcprivacy
```

CocoaPods App:

```text
NearWireSDKPrivacy.bundle/PrivacyInfo.xcprivacy
NearWirePerformancePrivacy.bundle/PrivacyInfo.xcprivacy
```

The base manifest declares linked Device ID for App Functionality with tracking disabled. The Performance manifest separately declares linked Performance Data for App Functionality with tracking disabled.

## App Privacy Report attempt

The unsigned archive was successfully created at `/tmp/nearwire-demo-spm-unsigned.xcarchive`. Computer Use then attempted to open Xcode Organizer, but macOS returned exactly:

```text
Computer Use permissions are not granted
```

Local Xcode tool discovery also returned:

```text
xcrun: error: unable to find utility "privacytool", not a developer tool or in PATH
xcrun: error: unable to find utility "appprivacyreport", not a developer tool or in PATH
```

No App Privacy Report is claimed. Xcode Organizer report export remains a mandatory `release-hardening` action together with the configured signed-archive entitlement and stable-signer matrix.
