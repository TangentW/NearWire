# SwiftPM Build, Launch, and Archive Evidence

## Result

Task 6.1 passed on 2026-07-14.

The SwiftPM App built in Swift 5 language mode for an arm64 iOS Simulator, its three compact unit tests and one UI launch test passed, and an interactive harness install/launch reached a stable screen. UI inspection found the `Viewer pairing code` text field and the saved screenshot showed the connection, Event lab, and Viewer controls. The Viewer independently built from the root workspace. Existing SDK and Viewer bidirectional and route-affinity regressions passed as recorded in `validation-5.3-production-regressions.md`.

## Simulator launch

```text
Device: iPhone 17 Pro
UDID: AF763A53-66CF-405B-AE92-F5A9CDECE0CE
Runtime: iOS 26.5 (23F77)
Bundle: com.nearwire.demo.spm
Harness install: ok
Harness launch: ok
Stable screen: true after 2 seconds
Accessibility scan: TextField label "Viewer pairing code", value "Pairing code"
Screenshot: /Users/tangent/.ios-vibe-harness/sessions/20260714-195400-nearwire-demo-smoke-/nearwire-demo-home-20260714-195405.png
```

## Unsigned generic iOS archive

```sh
xcodebuild -workspace NearWire.xcworkspace -scheme NearWireDemo -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/nearwire-demo-spm-unsigned.xcarchive -derivedDataPath /tmp/nearwire-demo-archive-derived -clonedSourcePackagesDirPath /tmp/nearwire-demo-archive-packages CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES archive
# exit 0; ARCHIVE SUCCEEDED
```

Archive identity:

```text
Path: /tmp/nearwire-demo-spm-unsigned.xcarchive
ApplicationPath: Applications/NearWireDemo.app
Architecture: arm64
Bundle identifier: com.nearwire.demo.spm
Version/build: 0.1.0 (1)
SigningIdentity: empty
Team: empty
```
