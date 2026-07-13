# Task 2.1 Schema Migration Evidence

Date: 2026-07-13

## Implemented contract

- Schema version 2 adds only `EventCausalityLookup`, `GapTimelineAllDevices`, and
  `GapTimelineByDevice`.
- A schema-1 upgrade runs on the StoreRuntime reopen executor with an exact cancellable migration
  token. Production startup constructs the store asynchronously so listener startup is independent
  from migration work.
- The migration writer uses `temp_store=FILE` and a 32-MiB cache target. It is always closed before
  a fresh normal writer and two readers are opened with `temp_store=MEMORY` and 8-MiB cache targets.
- Preflight validates an existing owner-controlled mode-0700 nonsymlink temporary directory,
  checked `512 MiB + 6 * allocated footprint` headroom, and the 256-MiB live floor. Physical volumes
  are checked once when identical and independently when distinct.
- The schema-1 transaction is rollback-safe, publishes bounded content-free status, installs the
  SQLite progress callback only for schema-1 migration, and supports once-per-process automatic
  authorization plus explicit retry.

## Focused migration tests

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testVersionOneMigrationPreservesContentAndPublishesOnlyFreshNormalConnections -only-testing:NearWireViewerTests/ViewerStoreTests/testVersionOneMigrationRollsBackEveryInjectedIndexAndValidationFailure -only-testing:NearWireViewerTests/ViewerStoreTests/testVersionOneMigrationRejectsUnsafeTemporaryDirectoriesAndBothVolumeShortfalls test
```

Result: `TEST SUCCEEDED`; 3 tests executed, 0 failures.

Additional focused tests covered asynchronous safe status, runtime availability during migration,
automatic-attempt authorization, explicit retry, and cancellation joined through rollback. Every
focused run completed with 0 failures.

## Store regression suite

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests test
```

Result: `TEST SUCCEEDED`; 98 tests executed, 1 test skipped, 0 failures. The skipped test is the
existing opt-in Application Support artifact audit, which requires the explicit machine-local
`/tmp/nearwire-live-container-audit.enabled` marker.

Two maintenance tests initially exposed an obsolete fixture assumption that bootstrap left pending
WAL work. The required migration-writer close removes that incidental state. Their fixtures now
create explicit WAL work before exercising maintenance recovery; both focused reruns and the full
suite pass.

## Static and specification validation

- `rg` found no production reference to `sqlite3_temp_directory`, `temp_store_directory`,
  `SQLITE_TMPDIR`, `TMPDIR`, `sqlite3_vfs_register`, or `sqlite3_vfs_unregister`.
- `openspec validate viewer-event-explorer-control --strict` reported
  `Change 'viewer-event-explorer-control' is valid`. The command later emitted a non-gating
  PostHog DNS flush error because telemetry networking is unavailable.
- `git diff --check` passed.

## Environment boundary

The first sandboxed Xcode invocation could not write Xcode/SwiftPM caches. The unrestricted build
then reached the configured development-team signing gate. Per the user-approved Goal policy,
configured signing and entitlement validation remains deferred to final `release-hardening`.
Compilation and tests use `CODE_SIGNING_ALLOWED=NO`, `ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64` on
this Apple-silicon host; this does not claim that signing validation passed.
