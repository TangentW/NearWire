# Implementation Validation — Round 3

Date: 2026-07-13 (Asia/Shanghai)

All results below were collected from the current `viewer-local-store-search` working tree after Round 2 remediation. Configured signing, entitlement assertions, and the stable-signer update probe remain explicitly deferred by the user to the goal-level `release-hardening` change. No validation requirement was removed or weakened.

## OpenSpec and diff hygiene

Command:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
```

Exact result:

```text
Change 'viewer-local-store-search' is valid
```

Command:

```text
git diff --check
```

Exact result: exit 0 with no output.

## Focused Viewer store regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -only-testing:NearWireViewerTests/ViewerStoreTests
```

Exact summary:

```text
Test Suite 'ViewerStoreTests' passed.
Executed 35 tests, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

## Complete unsigned Viewer regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Exact summary:

```text
Test Suite 'ViewerFlowControlTests' passed.
Executed 23 tests, with 0 failures (0 unexpected).
Test Suite 'ViewerFoundationTests' passed.
Executed 54 tests, with 0 failures (0 unexpected).
Test Suite 'ViewerStoreTests' passed.
Executed 35 tests, with 0 failures (0 unexpected).
Test Suite 'NearWireViewerTests.xctest' passed.
Executed 112 tests, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

The two skipped tests are the unchanged configured-signing gates reserved for `release-hardening` by user direction.

## Root Swift package regression

Command:

```text
swift test
```

Exact summary:

```text
Build complete! (1.83s)
Test Suite 'NearWirePackageTests.xctest' passed.
Executed 531 tests, with 0 failures (0 unexpected).
Test Suite 'All tests' passed.
Executed 531 tests, with 0 failures (0 unexpected).
```

The first restricted invocation could not write the compiler module cache. The identical command was rerun with approved Swift toolchain cache access and passed; source and validation settings were unchanged.

## SQLite linkage and built privacy manifest

Command:

```text
otool -L /tmp/NearWireViewerDerived/Build/Products/Debug/NearWire.app/Contents/MacOS/NearWire.debug.dylib
```

Relevant exact result:

```text
/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)
```

The Viewer links the system SQLite library. No SQLite or other third-party runtime package was added to Core, SDK, or the root package graph.

Command:

```text
find /tmp/NearWireViewerDerived/Build/Products/Debug/NearWire.app -name 'PrivacyInfo.xcprivacy' -print -exec plutil -p {} \;
```

Exact manifest categories:

```text
NSPrivacyAccessedAPICategoryUserDefaults: CA92.1
NSPrivacyCollectedDataTypeDeviceID: linked=true, tracking=false, purpose=AppFunctionality
NSPrivacyTracking: false
```

The built manifest retains the existing UserDefaults and device-identity declarations. The local filesystem capacity query is not transmitted, does not track, and does not introduce another collected-data declaration.

## Root package manifest inspection

Command:

```text
swift package dump-package
```

Exact relevant result:

```text
dependencies: []
platforms: iOS 16.0, macOS 13.0
swiftLanguageVersions: [5]
products: NearWire, NearWireUI, NearWirePerformance, NearWireCore
```

The Viewer store remains absent from the root Swift Package manifest. The only shared-source adjustment is internal transport SPI data already used by the Viewer integration; it adds no public SDK declaration or dependency.

## Coverage added since Round 2

The current tests now cover the shared protocol-to-writer count/byte budget and reserved lifecycle partition, exact failed-prefix flush outcome and explicit retry, duplicate peer Event UUIDs across consumer handoff, expiry, and session end, missing-initial transition gaps, projected-capacity admission, append-only frozen gap versions, disk-guard failure across bootstrap and mutations, annotation-bound one-time delete confirmation, Viewer receive time and type-strict JSON scalar semantics, frozen disposition/metadata membership, export plan gating, exact export commit/cancellation/fault phases, distinct SQLite work-limit reporting, mid-runtime nondurable device accounting, and replacement-runtime isolation from late prior-generation callbacks and cleanup.
