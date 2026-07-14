# Compact Demo Test Evidence

## Result

Tasks 5.1 and 5.2 passed on 2026-07-14 using iPhone 17 Pro Simulator AF763A53-66CF-405B-AE92-F5A9CDECE0CE on iOS 26.5.

The Demo unit target contains exactly three tests: the 512-byte UTF-8 boundary, valid/invalid banner-control mapping, and 49/50/51 summary retention. The UI target contains exactly one launch test covering the reference surface, pairing field, initial Not Connected state, Event control, Performance control, and initial Stopped state.

## Commands and exact outcomes

```sh
xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireDemo -configuration Debug -destination 'id=AF763A53-66CF-405B-AE92-F5A9CDECE0CE' -derivedDataPath /tmp/nearwire-demo-derived -clonedSourcePackagesDirPath /tmp/nearwire-demo-packages CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing
# exit 0

xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireDemo -configuration Debug -destination 'id=AF763A53-66CF-405B-AE92-F5A9CDECE0CE' -derivedDataPath /tmp/nearwire-demo-derived -clonedSourcePackagesDirPath /tmp/nearwire-demo-packages CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building -only-testing:NearWireDemoTests
# xcresult: Passed; 3 passed, 0 failed, 0 skipped

xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireDemo -configuration Debug -destination 'id=AF763A53-66CF-405B-AE92-F5A9CDECE0CE' -derivedDataPath /tmp/nearwire-demo-derived -clonedSourcePackagesDirPath /tmp/nearwire-demo-packages CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building -only-testing:NearWireDemoUITests/NearWireDemoUITests/testLaunchesReferenceSurface
# xcresult: Passed; 1 passed, 0 failed, 0 skipped
```

No Demo-owned queue, lifecycle, transport, TLS, concurrency, or alternate protocol test double was added.
