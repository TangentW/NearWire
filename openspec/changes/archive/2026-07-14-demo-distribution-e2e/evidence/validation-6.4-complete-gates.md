# Complete Validation Evidence

## Result

Task 6.4 passed on 2026-07-14 with the user-authorized configured-signing exclusion.

## Demo

The complete maintained Demo suite passed on iPhone 17 Pro Simulator iOS 26.5:

```text
Demo logic: 3 passed, 0 failed, 0 skipped
Demo UI launch: 1 passed, 0 failed, 0 skipped
```

## Viewer

The first unsigned full-suite command failed only at `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`, the exact configured-signing test assigned to `release-hardening`. No source or expectation was changed. The suite was rerun with only that test excluded:

```sh
xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-demo-viewer-complete -clonedSourcePackagesDirPath /tmp/nearwire-demo-viewer-complete-packages CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
# xcresult: Passed; 394 passed, 0 failed, 2 skipped
```

The two existing skips are machine-opt-in gates:

```text
ViewerFoundationTests.testStableSignerUpdateBoundaryProbe
ViewerStoreTests.testOptInLiveApplicationSupportArtifactsWhileViewerStoreIsOpen
```

The first remains part of configured-signing hardening. The second requires an explicit local-container audit marker and is not caused by the Demo change.

## Repository bootstrap gate

```sh
bash Scripts/verify-bootstrap.sh
# exit 0; All bootstrap quality gates passed.
```

Important exact results from the gate:

```text
OpenSpec: 33 passed, 0 failed
iOS Simulator root package tests: 536 passed, 0 failed, 4 existing skips
Core harness: 214 passed, 0 failed
Real TLS active-session integration: 1 passed
Public connect production TLS integration: 1 passed
Swift Package verification: passed
CocoaPods 1.16.2 private podspec lint: NearWire passed validation
Structure, English, validation-tool, version, module-boundary, process-lease,
session-admission, package, privacy-resource, consumer-API, TLS, and raw-channel gates: passed
```

The podspec's reserved `example.invalid` homepage produced its documented private-release warning; compilation and pod validation passed. Xcode emitted informational AppIntents metadata notes because the product does not link AppIntents.

## Final static gates

```sh
swift format lint --strict --recursive Demo
# exit 0

plutil -lint Demo/NearWireDemo/Resources/Info.plist SDK/Sources/NearWire/PrivacyInfo.xcprivacy SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy
# all OK

xmllint --noout NearWire.xcworkspace/contents.xcworkspacedata Demo/NearWireDemo.xcodeproj/xcshareddata/xcschemes/NearWireDemo.xcscheme Demo/NearWireDemo.xcodeproj/xcshareddata/xcschemes/NearWireDemoCocoaPods.xcscheme
# exit 0

plutil -lint Demo/NearWireDemo.xcodeproj/project.pbxproj
# OK

git diff --check
# exit 0

DO_NOT_TRACK=1 openspec validate demo-distribution-e2e --strict --no-interactive
# Change 'demo-distribution-e2e' is valid
```
