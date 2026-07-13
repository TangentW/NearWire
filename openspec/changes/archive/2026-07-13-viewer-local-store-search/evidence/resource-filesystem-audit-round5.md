# Resource, Filesystem, and Distribution Audit — Round 5

Date: 2026-07-13 (Asia/Shanghai)

## Live Application Support audit

The actual developer path already contained a pre-existing incomplete schema-v1 database from an earlier development run. The current Viewer correctly treated that unsupported artifact as unavailable. To avoid altering or misrepresenting it, the audit used this reversible sequence:

1. Move the complete pre-existing `~/Library/Application Support/NearWire` directory to `/tmp/NearWire-preaudit-20260713` without inspecting or deleting its contents.
2. Enable the opt-in live-container regression through `/tmp/nearwire-live-container-audit.enabled`.
3. Run `ViewerStoreTests.testOptInLiveApplicationSupportArtifactsWhileViewerStoreIsOpen` against a newly created actual Application Support store.
4. Launch the current built Viewer and verify its open descriptors with `lsof`.
5. Quit the Viewer normally and inspect the clean-close files.
6. Move the audit-created directory to `/tmp/NearWire-audit-created-20260713`, restore the original directory to its exact path, and remove the opt-in marker.

The opt-in test passed one test with zero failures. While the store was open:

```text
directory: /Users/tangent/Library/Application Support/NearWire
directory mode: 0700
main database: 188416 logical bytes, 188416 allocated bytes, mode 0600
WAL: 193672 logical bytes, 196608 allocated bytes, mode 0600
SHM: 32768 logical bytes, mode 0600
```

`lsof` showed Viewer process 20812 holding the actual Application Support database as descriptors 3/6/7, WAL as 4/8, and SHM as 5. After a normal application quit:

```text
main database: 188416 logical bytes, mode 0600
WAL: 0 logical bytes, mode 0600
SHM: 32768 logical bytes, mode 0600
directory mode: 0700
```

The original pre-existing directory was restored with its observed main/WAL/SHM logical sizes unchanged at 184320/0/32768 bytes. The temporary backup path no longer exists. This audit does not claim that the pre-existing incomplete schema is supported.

## Incremental-vacuum reclamation

`testIncrementalVacuumUsesFloorOnlyAndMeasuresPhysicalReclaim` inserted 512 independent 16 KiB payloads and deleted their session, then ran one bounded incremental-vacuum turn at `64 MiB + 1` available bytes:

```text
freelist_count: 2112 -> 2048
page_count: 2161 -> 2097
main logical size: 8851456 -> 8851456
main allocated bytes: 8851456 -> 8851456
WAL allocated bytes: 0 -> 12288
```

The test separately proves that one byte below the 64 MiB floor fails before mutation. SQLite returned 64 pages from the freelist and reduced the database page count by 64. On the audited APFS volume, those page-level changes did not immediately reduce the main file's logical or allocated size because WAL/checkpoint and filesystem allocation behavior are separate concerns. The implementation and operator documentation therefore promise bounded reclamation work and measured SQLite progress, not immediate byte-for-byte APFS shrinkage.

## Current resource boundaries

| Boundary | Current-tree result |
|---|---|
| Sustained writes | 1,000 Events in ten 100-Event batches; allocated WAL 2,076,672 bytes, below 64 MiB |
| Near-maximum Event | Deterministic record 15,729,853 bytes; one-record oversize path passed |
| Query page | 1...200 rows, at most eight finite leases, 250 ms/VM budget, frozen keyset bounds, no `OFFSET` |
| Export page | 200 rows or 64 KiB, one finite lease, one-second page budget, 60-minute absolute lifetime |
| Normal write | 256 records or 4 MiB |
| Oversize write | One record up to 20 MiB |
| Physical reclaim | 1,024 rows or 4 MiB normally; one Event/FTS reclaim plan up to 41 MiB |
| Volume reserve | Checked `64 MiB + action-specific planned bytes`; equality passes and one byte below fails |

## Distribution and privacy matrix

| Gate | Exact current result |
|---|---|
| Root `swift test` | 531 tests, 7 skipped, 0 failures |
| Viewer unsigned regression | 126 tests, 1 opt-in skip, 0 failures; two configured-signing tests intentionally excluded |
| CocoaPods validation | Existing verification script passed unchanged under CocoaPods 1.16.2; only the pre-existing example-URL warning |
| Root manifests only | `./Package.swift` and `./NearWire.podspec` |
| System SQLite | Built Viewer debug dylib links `/usr/lib/libsqlite3.dylib` |
| Built privacy manifest | Byte-identical to checked-in Viewer manifest; UserDefaults `CA92.1`; linked nontracking Device ID for app functionality; tracking false |

## Deferred configured-signing gate

The entitlement assertion and stable-signer update-boundary probe require project-specific signing configuration. Per user direction, they remain visible and unchanged for the final goal-level `release-hardening` change and are not represented as passing here.
