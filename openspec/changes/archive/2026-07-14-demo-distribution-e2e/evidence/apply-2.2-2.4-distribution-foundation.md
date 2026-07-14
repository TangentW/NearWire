# Distribution Foundation Evidence

## Result

Tasks 2.2 through 2.4 passed on 2026-07-14.

The root workspace lists `NearWireDemo`, `NearWireDemoCocoaPods`, and `NearWireViewer`. The committed Demo project resolves the local package through `..`; the SwiftPM Demo and Viewer build independently with no generated CocoaPods state. The temporary CocoaPods workspace builds the second App target from identical production source and resource membership.

## Commands and exact outcomes

```sh
xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireDemo -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/nearwire-demo-derived -clonedSourcePackagesDirPath /tmp/nearwire-demo-packages CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
# exit 0; BUILD SUCCEEDED

xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/nearwire-demo-viewer-derived -clonedSourcePackagesDirPath /tmp/nearwire-demo-viewer-packages CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
# exit 0

pod --version
# 1.16.2

pod install --project-directory=Demo --no-repo-update
# Pod installation complete; 2 dependencies from the Podfile and 1 total pod installed

xcodebuild -quiet -workspace Demo/NearWireDemo.xcworkspace -scheme NearWireDemoCocoaPods -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/nearwire-demo-cocoapods-derived CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
# exit 0; BUILD SUCCEEDED

bash Scripts/verify-structure.sh
# Repository structure verification passed.

bash Scripts/verify-version.sh
# Version verification passed for 0.1.0.

ruby Scripts/check-swift-boundaries.rb
# Swift module import boundaries passed.
```

Both App targets contain the same five production Swift files and the same `Assets.xcassets` resource. Only the SwiftPM target defines `NEARWIRE_DEMO_SEPARATE_MODULES`; it guards imports and does not alter public call sites. No development team, provisioning profile, certificate hash, entitlements file, generated Pods directory, generated workspace, or Podfile lock exists in the repository.
