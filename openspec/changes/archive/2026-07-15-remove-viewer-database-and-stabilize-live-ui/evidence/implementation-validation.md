## Viewer build and strict concurrency

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-memory-ui-build CODE_SIGNING_ALLOWED=NO build-for-testing
```

Result: exit 0, `** TEST BUILD SUCCEEDED **`. The Viewer and test targets compiled in Swift 5 language mode with `StrictConcurrency` enabled.

## Focused behavior tests

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-memory-ui-build CODE_SIGNING_ALLOWED=NO test-without-building \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testMemorySessionExportImportRoundTripDoesNotCreateAStore \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationModelDoesNotLoadOrSaveLegacyStorageSettings \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests/testRetainedPerformanceRefreshPublishesOnlyWhenVisibleResultChanges \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testControlComposerScalesToCompactWidthWithDeterministicEditorFocusOrder
```

Result: exit 0, 4 tests executed with 0 failures. This covers memory-only Session transfer, removal of application Store configuration/status work, retained Performance publication suppression, and a real native edit in the Event type field.

## Full functional Viewer suite

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-memory-ui-build CODE_SIGNING_ALLOWED=NO test-without-building \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements
```

Result: exit 0, 466 tests executed, 2 skipped, 0 failures. The one excluded test reads entitlements from the running process and cannot pass in the intentionally unsigned `CODE_SIGNING_ALLOWED=NO` validation build. Signing remains a final environment verification and was not changed by this OpenSpec scope.

## Source and catalog checks

- `git diff --check`: exit 0.
- `jq empty Viewer/NearWireViewer/Resources/Localizable.xcstrings`: exit 0.
- The focused localization catalog test passed with complete English and Simplified Chinese entries for the changed memory-Session copy.

## Post-review regression closure

The first independent review round found real production-path issues in memory-only Timeline traversal, Performance targeting, Clear/Import presentation invalidation, bounded diagnostic transfer, retained Performance crosshair publication, frozen export cancellation, and the obsolete Store catalog request at memory-mode startup. All findings were fixed without changing SDK or transport behavior.

The fresh closure round returned `NO FINDINGS` from architecture/API, correctness/testing, and security/performance/documentation reviewers. Targeted follow-up confirmed that memory startup no longer requests Store catalogs and cancelled export execution atomically consumes its frozen unencrypted JSON ticket without introducing a new race.

Final build command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-memory-ui-build CODE_SIGNING_ALLOWED=NO build-for-testing
```

Result: exit 0, `** TEST BUILD SUCCEEDED **` after all review fixes and the final Timeline presentation change.

Final focused command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-memory-ui-build CODE_SIGNING_ALLOWED=NO test-without-building \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testMemoryOnlyExplorerPublishesLiveEventsWithoutStoreTraversal \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testMemorySessionExportImportRoundTripDoesNotCreateAStore \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests/testRetainedPerformanceRefreshPublishesOnlyWhenVisibleResultChanges
```

Result: exit 0, 3 tests executed with 0 failures. The memory Explorer test also asserts the compact JSON content summary derived for the visible Timeline row.

The final Timeline omits per-row `In memory` and normal `consumerAccepted` badges, retains actionable status badges, leads with a one-line compact JSON summary derived from at most 256 UTF-8 bytes, and presents Event type as secondary un-emphasized metadata.

## Final spec-to-evidence audit

- `git diff --check`: exit 0.
- `jq empty Viewer/NearWireViewer/Resources/Localizable.xcstrings`: exit 0.
- `openspec validate remove-viewer-database-and-stabilize-live-ui --strict`: the change is valid. The CLI later reported only its blocked optional telemetry upload to `edge.openspec.dev`; validation itself completed successfully.
- Every requirement and scenario in the active capability deltas maps to implementation, focused test/build evidence, or the recorded bounded render inspection. No unresolved review finding remains.
