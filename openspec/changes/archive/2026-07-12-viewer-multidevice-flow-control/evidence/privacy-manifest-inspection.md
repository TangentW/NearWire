# Built Privacy Manifest Inspection

Date: 2026-07-13

Command:

```text
find /tmp/nearwire-viewer-final-r4/Build/Products/Debug/NearWire.app -name PrivacyInfo.xcprivacy -print -exec plutil -p {} \;
```

Result: passed. The built app contained `Contents/Resources/PrivacyInfo.xcprivacy` with:

```text
NSPrivacyAccessedAPICategoryUserDefaults
reason: CA92.1
NSPrivacyCollectedDataTypeDeviceID
linked: true
purpose: NSPrivacyCollectedDataTypePurposeAppFunctionality
tracking: false
NSPrivacyTracking: false
```

Conclusion: the existing declaration covers the bounded `ViewerDevicePreferences` use of `UserDefaults` and the peer-declared stable correlation value used for App functionality. This change adds no tracking domain, analytics SDK, Event-content persistence, or new required-reason API category.
