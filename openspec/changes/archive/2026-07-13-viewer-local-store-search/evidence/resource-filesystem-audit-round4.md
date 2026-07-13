# Resource, Filesystem, and Distribution Audit — Round 4

Date: 2026-07-13 (Asia/Shanghai)

## Resource boundaries

| Boundary | Current-tree evidence | Result |
|---|---|---|
| Sustained writes | `testSustainedBatchesKeepWALBoundedAndStoreArtifactsSecureThroughClose` writes 1,000 Events in ten 100-Event batches | Passed; allocated WAL was 2,076,672 bytes, below 64 MiB |
| Near-maximum Event | `testNearMaximumPayloadUsesBoundedOversizeTransaction` uses a valid custom 16 MiB content limit and a 15 MiB payload | Passed; deterministic Event record was 15,729,853 bytes and used the one-record oversize path |
| Peak process memory | `/usr/bin/time -l` around the focused near-maximum test | Maximum RSS 206,372,864 bytes; peak memory footprint 107,627,576 bytes; the test itself completed in 0.132 seconds |
| Query page | Production validator and query service | 1...200 rows, eight finite leases, 250 ms/VM budget, frozen keyset bounds, no `OFFSET` |
| Export page | Export service | 200 rows or 64 KiB, one finite lease, one-second page budget, 60-minute absolute lifetime |
| Normal write | Store ingress and writer | 256 records or 4 MiB |
| Oversize write | Store ingress and writer | One record up to 20 MiB |
| Physical reclaim | Maintenance | 1,024 rows or 4 MiB normally; one Event/FTS reclaim plan up to 41 MiB |
| Volume reserve | Disk guard | Requires checked `64 MiB + planned bytes`; equality passes and one byte below fails |

The `/usr/bin/time` figures cover the end-to-end `xcodebuild` test process, not an isolated production Viewer process. They are retained as a reproducible upper-context measurement rather than presented as an application-only benchmark.

## Filesystem and atomicity matrix

| Requirement | Evidence | Result |
|---|---|---|
| Owner-only store directory | `testStoreCreatesThreeRolesAndVersionOneSchemaWithOwnerOnlyPermissions` | Directory is `0700` |
| Owner-only main/WAL/SHM | Same test and sustained-write test | Existing regular files are `0600` during activity and after close |
| No symlink traversal | `testSymlinkDatabaseAndDirectoryAreRejected` | Database and directory symlinks rejected |
| Temporary export identity | `testExportRejectsTemporaryLeafHardLinkAndParentSubstitution` | Regular-file substitution, hard link, symlink, and parent substitution rejected |
| Atomic destination preservation | `testExportCommitBoundaryPreservesDestinationAcrossInjectedFailuresAndCancellation` | Pre-commit failures/cancellation leave prior destination unchanged; post-commit result is complete |
| Descriptor-relative commit | Export implementation inspection | Retained parent fd, `openat`, identity checks, `renameat`, and parent `fsync` |
| Secure-delete posture | Schema/configuration tests and operator documentation | SQLite secure-delete enabled; documentation does not promise physical erasure from WAL/filesystem/backup copies |

## Distribution and privacy matrix

| Gate | Exact current result |
|---|---|
| Root `swift test` | 531 tests, 0 failures |
| Viewer unsigned regression | 121 tests, 0 failures; only two configured-signing tests intentionally excluded |
| CocoaPods validation | Existing `Scripts/verify-podspec.sh` passed unchanged after rerun outside the restricted proxy sandbox; CocoaPods 1.16.2 reported only the pre-existing example-URL warning |
| Podspec syntax | `ruby -c NearWire.podspec`: `Syntax OK` |
| Root manifests only | `./Package.swift` and `./NearWire.podspec`; no nested manifest |
| Manifest hashes | `Package.swift`: `93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1`; `NearWire.podspec`: `4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33` |
| System SQLite | Built Viewer links `/usr/lib/libsqlite3.dylib`; no added Core/SDK runtime dependency |
| Built privacy manifest | UserDefaults reason `CA92.1`; linked nontracking device ID for app functionality; tracking false |

The first restricted CocoaPods attempt could not reach its configured local proxy at `127.0.0.1:7890`; the identical repository script passed with approved external access. The first restricted `swift test` attempt could not write compiler/SwiftPM caches; the identical command passed with approved cache access. Neither command nor source was weakened.

## Deferred configured-signing gate

The entitlement assertion and stable-signer update-boundary probe require project-specific signing configuration. Per user direction, they remain visible and unchanged and will be executed in the final goal-level `release-hardening` change. This deferral is not treated as evidence that those tests passed.
