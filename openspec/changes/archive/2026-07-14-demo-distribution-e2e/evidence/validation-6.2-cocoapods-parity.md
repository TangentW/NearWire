# CocoaPods Distribution Parity Evidence

## Result

Task 6.2 passed on 2026-07-14.

The validation root was `/private/tmp/nearwire-demo-cocoapods-root`. It preserved the repository topology required by the Demo project's `..` local-package reference and contained the canonical copied Package.swift, podspec, version, license, Core, SDK, and Demo inputs. CocoaPods 1.16.2 installed only inside that temporary root and the generated workspace built `NearWireDemoCocoaPods` for an arm64 iOS Simulator with Swift warnings as errors.

## Source, resource, and call-site parity

Both targets reported the same five production source files and one asset catalog:

```text
Demo/NearWireDemo/App/NearWireDemoApp.swift
Demo/NearWireDemo/Application/DemoApplicationModel.swift
Demo/NearWireDemo/Application/DemoDriver.swift
Demo/NearWireDemo/Application/DemoModels.swift
Demo/NearWireDemo/UI/DemoRootView.swift
Demo/NearWireDemo/Resources/Assets.xcassets
```

Final hashes were identical in the repository and the installed temporary root:

```text
Production source/resource tree SHA-256: 9f0cfd2da2f721f79dc390f76d9233fa0c9b69687d4bc298054b061e722cb698
Public NearWire/Performance/UI call-site SHA-256: d1ea146e10ad180a40524439d41b5b3de557f6ebad0bd2bd4f5926ca27fb0658
```

## Repository isolation

`Demo/Pods`, `Demo/Podfile.lock`, and the generated `Demo/NearWireDemo.xcworkspace` do not exist in the repository after validation. `Scripts/verify-structure.sh` passed and Git status contains only the intentional active-change files, not generated CocoaPods output or build products.
