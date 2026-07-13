# Implementation Validation — Round 1

Date: 2026-07-13 (Asia/Shanghai)

All commands ran against the current `viewer-local-store-search` working tree. Configured-signing checks remain explicitly deferred to the goal-level `release-hardening` change at the user's direction.

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

## Focused Viewer store tests

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -only-testing:NearWireViewerTests/ViewerStoreTests
```

Exact summary:

```text
Test Suite 'ViewerStoreTests' passed.
Executed 12 tests, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

Coverage in this focused suite includes three connection roles, first creation, reopen, unknown schema rejection, real defensive/trusted-schema configuration, secure-delete and permissions, symlink rejection, checked bindings, rollback, preferences and corruption recovery, Event idempotence, literal query compilation, frozen keyset page behavior, export disclosure/aliases/permissions/JSON validity, lease-protected revision-bound deletion, bounded text validation, and storage settings presentation logic.

## Complete unsigned Viewer regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Exact summary:

```text
Test Suite 'ViewerFlowControlTests' passed.
Executed 22 tests, with 0 failures (0 unexpected).
Test Suite 'ViewerFoundationTests' passed.
Executed 54 tests, with 0 failures (0 unexpected).
Test Suite 'ViewerStoreTests' passed.
Executed 11 tests, with 0 failures (0 unexpected).
Test Suite 'NearWireViewerTests.xctest' passed.
Executed 87 tests, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

The later focused store run added one presentation/settings test, bringing the focused store count to 12. The two excluded tests require configured signing and are reserved for `release-hardening`; they are not weakened or deleted.

The first all-test attempt also ran the two signing checks under `CODE_SIGNING_ALLOWED=NO`, so their entitlement assertions failed as expected. That attempt exposed one existing asynchronous mailbox test timeout. The exact isolated rerun command was:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -only-testing:NearWireViewerTests/ViewerFlowControlTests/testAuthoritativeMailboxBackpressureAlsoRetriesWithoutCommittingSequence
```

Exact isolated result:

```text
Executed 1 test, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

The subsequent 87-test regression also passed that mailbox test in suite context.

## Root Swift package regression

Command:

```text
swift test --scratch-path /tmp/NearWireSwiftBuild
```

Exact summary:

```text
Build complete! (20.74s)
Test Suite 'NearWirePackageTests.xctest' passed.
Executed 531 tests, with 0 failures (0 unexpected).
Test Suite 'All tests' passed.
Executed 531 tests, with 0 failures (0 unexpected).
```

The first sandboxed invocation could not write the toolchain's user compiler cache. The same unchanged command was rerun with the already-approved toolchain access and passed; no validation gate was weakened.

## Unsigned Viewer build and SQLite linkage

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache build
```

Exact result:

```text
** BUILD SUCCEEDED **
```

The link invocation contains `-lsqlite3`. No third-party dependency was added to the root package manifest or to Core/SDK.
