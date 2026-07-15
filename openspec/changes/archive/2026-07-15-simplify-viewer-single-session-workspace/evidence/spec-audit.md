# Spec-to-Evidence Audit

Audited on 2026-07-15 against the final source tree and the strict-valid OpenSpec change.

## Viewer application foundation

- One process-scoped runtime and Session, bounded termination, listener recovery, and the absence of historical Source lifetime are covered by `testTerminationJoinsBlockedExplorerCleanupAndFreshRuntimeHasNoPriorContent`, `testApplicationTerminationRetainsWorkingStoreCleanupAfterBoundedTimeout`, and the complete Viewer suite.
- The native single-window composition, top Devices area, truthful action states, and macOS compatibility are covered by `testRootViewComposesWithoutStartingRuntime`, `testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt`, `testWorkspaceRegionsExposeDevicesAndIndependentPanelsWithoutSources`, and the signed Viewer build.
- Fixed recovery text and transport disclosure remain covered by `testPresentationErrorsExposeOnlyFixedRecoveryText` and the existing foundation security tests.

## Event workspace and controls

- All-Devices and exact multi-Device selection, offline imported Devices, and Performance's one-Device boundary remain covered by the Event Explorer and Performance controller suites.
- Connected Clear, cancelled confirmation, inactive-only import, exclusive operation state, generation replacement, and stale-work rejection are covered by `testWorkspaceMutationPolicyAllowsConnectedClearButRejectsConnectedImport`, `testWorkspaceOperationsPublishImmediateExclusiveAndCancellableStates`, `testClearCurrentSessionRemovesEventDerivedRowsAndPreservesDeviceCapture`, and the workspace-mutation ordering tests.
- Independent Timeline, Inspector, and Composer visibility and the both-hidden placeholder are covered by root composition, panel-layout, accessibility, and six-variant render tests.
- Region-scoped publication and animation-safe Event arrival are covered by `testTimelineOnlyMutationDoesNotPublishInspectorPresentation`, `testFilterPresentationIgnoresTimelineOnlyPublications`, stable-row tests, high-frequency publication tests, and render inspection.

## Local Store and Session transfer

- Distinct process workspaces, terminal cleanup, schema acceptance, and schema-version-2 to version-3 retained-counter migration are covered by Store lifecycle tests and `testVersionTwoMigrationAddsRetainedCountersForExistingContent`.
- Atomic generation-safe Clear and admitted-ingress ordering are covered by the Clear rollback, prefix-drain, stale-generation, and `testWorkLimitRejectionsDrainIngressAndLeaveClearReusable` tests.
- Complete Session JSON round trip, regenerated local identities, reconnect rows, cancellation, malformed and oversized input, symbolic-link rejection, bounded incremental export, and inactive-only admission are covered by the Session import/export suite.
- Previous schema-version-1 complete exports remain importable after warning-copy changes, as proved by `testCompleteSessionImportAcceptsLegacyVersionOneDisclosureWarning`.
- Diagnostic Gap identities remain unique after import and same-process reopen, as proved by `testImportedCoordinatorGapSequenceAdvancesBeforeNewRuntimeGap` and `testReopenedCoordinatorResumesDurableGapSequence`.

## Performance projection

- Clear and import invalidate predecessor projection generations and rebuild only from successor raw Events through the existing projection-generation, raw-resolution, controller replacement, and workspace-rematerialization tests.
- The 100,000-input bounded projection diagnostic passed in the final suite while retaining exact caps and cleanup ownership.

## Cross-checks

- Final Viewer suite: 437 tests executed, 2 environment-dependent packaging probes skipped, 0 failures.
- Root package: 546 tests executed, 0 failures.
- Demo simulator build: passed for both simulator architectures.
- Minimum, standard, and wide Viewer layouts: passed in light and dark appearances, with six retained XCTest images and one saved full-window screenshot.
- Strict OpenSpec validation and `git diff --check`: passed.

No requirement or scenario lacks matching implementation, automated validation, or documented visual evidence. The two skipped packaging probes require external signing/update configuration and are unrelated to this Viewer workspace change.
