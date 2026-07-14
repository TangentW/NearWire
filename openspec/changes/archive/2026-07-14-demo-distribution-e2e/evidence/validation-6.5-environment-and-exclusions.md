# Environment, Products, and Final Exclusions

## Toolchain identity

```text
macOS: 26.5.1 (25F80)
Xcode: 26.6 (17F113)
Apple Swift compiler: 6.3.3, distributed source compiled in Swift 5 language mode
CocoaPods: 1.16.2
```

## Simulator identity and counts

```text
Interactive Demo: iPhone 17 Pro, iOS 26.5, AF763A53-66CF-405B-AE92-F5A9CDECE0CE
Root package gate: iPhone 17 Pro, iOS 26.4, 28489DFE-9F3F-4746-98C6-F956F47FEC0C
Demo tests: 3 logic + 1 UI launch, all passed
Viewer non-signing suite: 394 passed, 2 existing machine-opt-in skips
Root iOS package suite: 536 passed, 4 existing platform/environment skips
Core harness: 214 passed
Focused production regressions: 2 SDK route/reply + 1 TLS public-connect + 1 Viewer bidirectional, all passed without final skips
Privacy resources per App: 2
```

## Product paths

```text
SwiftPM Simulator App: /tmp/nearwire-demo-derived/Build/Products/Debug-iphonesimulator/NearWireDemo.app
CocoaPods Simulator App: /tmp/nearwire-demo-cocoapods-derived/Build/Products/Debug-iphonesimulator/NearWireDemoCocoaPods.app
Unsigned generic iOS archive: /tmp/nearwire-demo-spm-unsigned.xcarchive
Unsigned archived App: /tmp/nearwire-demo-spm-unsigned.xcarchive/Products/Applications/NearWireDemo.app
```

The archive is arm64, version 0.1.0 build 1, bundle identifier `com.nearwire.demo.spm`, with empty SigningIdentity and Team. It contains the exact SDK and Performance privacy manifests and no code signature, provisioning profile, or entitlement file.

## Required release-hardening work

The following checks remain mandatory and are not claimed by this change:

1. Enable the required Xcode/Computer Use UI permission and export the Xcode Organizer App Privacy Report from the final configured signed archive.
2. Configure the authorized development team and signing identities.
3. Assert the embedded entitlements of signed Viewer and iOS running products.
4. Run the stable-signer update and Keychain continuity matrix.
5. Perform the final signed real-device launch and local-network permission verification.

The user explicitly assigned configured signing to terminal `release-hardening`. The App Privacy Report joined that gate only because macOS denied Organizer UI automation and the installed Xcode exposes no CLI exporter. No signed-product or privacy-report completion claim is made here.
