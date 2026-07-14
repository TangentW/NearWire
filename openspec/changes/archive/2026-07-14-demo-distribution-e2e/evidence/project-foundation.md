# Project Foundation Evidence

## Project parse

```text
plutil -lint Demo/NearWireDemo.xcodeproj/project.pbxproj
Demo/NearWireDemo.xcodeproj/project.pbxproj: OK
```

## Xcode inventory

Command used writable derived/package locations because the sandbox cannot write the default Xcode
cache directory:

```text
xcodebuild -list -json \
  -project Demo/NearWireDemo.xcodeproj \
  -scheme NearWireDemo \
  -derivedDataPath /tmp/nearwire-demo-list-derived \
  -clonedSourcePackagesDirPath /tmp/nearwire-demo-list-packages
```

Result: exit 0. Xcode reported the maintained targets `NearWireDemo`,
`NearWireDemoCocoaPods`, `NearWireDemoTests`, and `NearWireDemoUITests`, plus the shared
`NearWireDemo` and `NearWireDemoCocoaPods` schemes. The SwiftPM target resolves the repository-local
`NearWire`, `NearWireUI`, and `NearWirePerformance` products. Project settings use iOS 16 and Swift
5 language mode and contain no development team, provisioning profile, certificate hash, or project
generator metadata.
