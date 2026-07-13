# Task 6.6 History Operations and Export Integration Evidence

Date: 2026-07-13

## Revision-bound history operations

- `testExplorerGatewayRoutesRevisionBoundHistoryMutationsAndRejectsOldGeneration` uses one real
  coordinator, store, maintenance service, catalog, and explorer gateway. It proves that an active
  recording cannot produce a delete confirmation; a closed recording can be renamed, noted, and
  pinned only at its exact revision; cancellation cannot misreport a non-cancellable committed
  metadata write; and an old target returns the bounded `busy` failure.
- The same integration advances cleanup beyond the default TTL and proves the pinned recording is
  not tombstoned. It appends an annotation, invalidates a prepared delete with a later annotation,
  and verifies that the stale confirmation is single-use and creates no tombstone.
- A real frozen query then holds a lease for the recording. Delete execution is rejected while that
  lease protects history, consumes the attempted confirmation, and leaves no tombstone. Ending the
  traversal releases the lease; a fresh confirmation succeeds and creates exactly one tombstone.
- Installing a replacement coordinator rejects the original target as `storeReplaced` rather than
  retargeting it to unrelated storage.
- `testRevisionBoundDeleteHonorsLeaseAndMaintenanceReclaimsSession` independently proves that a
  leased recording cannot be deleted, release permits a fresh confirmation, and explicit
  maintenance reclaims the tombstoned session.

## Frozen export, disclosure, and atomic destination

- `testExplorerGatewayFreezesPreflightedExportsAndCancellationPreservesDestination` preflights
  complete and current-filtered exports through the gateway. The complete ticket freezes two
  Events; the filtered ticket freezes one matching Event; a later matching durable Event appears in
  neither ticket. Both executions contain their exact frozen counts.
- The ticket exposes the fixed disclosure that Event content may contain sensitive data, JSON is
  unencrypted, aliases are pseudonyms rather than redaction, the exported file is outside Viewer
  quota/retention, and a destination provider may sync or back it up. Ticket reflection is closed.
- Cancelling an export behind the gateway execution gate returns `cancelled` and preserves the
  previous destination bytes. Replacing the coordinator makes the prior ticket `storeReplaced` and
  creates no destination.
- `testExportCommitBoundaryPreservesDestinationAcrossInjectedFailuresAndCancellation` injects
  every precommit file-phase failure and cancellation before the commit seal. Each preserves the
  previous destination; cancellation or failure after the atomic rename does not make a committed
  export appear partial.
- `testExportUsesAliasesAndDisclosureWithoutRawInstallationIdentifier` verifies owner-only file
  permissions, the fixed JSON schema, pseudonymous device/connection aliases, causality, gaps, and
  annotations, while excluding raw installation identity, session epoch, pairing, and certificate
  data.

## Viewer-safe presentation

- `testExplorerOperationMessagesAndExportExclusionDisclosureAreFixedAndSafe` covers every typed
  explorer failure. Each maps to one nonempty, distinct operator message without filesystem paths,
  SQLite details, or underlying-error labels.
- The UI consumes one shared exact disclosure string:
  `Transient rows labeled Not recorded are excluded.` Complete and filtered exports therefore never
  imply that nondurable live rows were written.
- `testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt` exercises unavailable history and
  export operations through the running application root. Both become typed UI-safe failures, and
  termination clears their controllers and presentation state.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayRoutesRevisionBoundHistoryMutationsAndRejectsOldGeneration -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayFreezesPreflightedExportsAndCancellationPreservesDestination -only-testing:NearWireViewerTests/ViewerStoreTests/testRevisionBoundDeleteHonorsLeaseAndMaintenanceReclaimsSession -only-testing:NearWireViewerTests/ViewerStoreTests/testExportUsesAliasesAndDisclosureWithoutRawInstallationIdentifier -only-testing:NearWireViewerTests/ViewerStoreTests/testExportCommitBoundaryPreservesDestinationAcrossInjectedFailuresAndCancellation -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerOperationMessagesAndExportExclusionDisclosureAreFixedAndSafe -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt
```

Result: `TEST SUCCEEDED`; 7 tests executed, 0 failures.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 233 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The configured
signing entitlement assertion remains deferred to Goal-level release hardening as approved by the
user. This unsigned run makes no release-signing claim.

## Static and specification validation

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
