# Implementation Remediation — Round 4

Date: 2026-07-13 (Asia/Shanghai)

This record maps every actionable Round 4 implementation-review finding to the current source, regression coverage, and validation evidence. Configured-signing checks remain deferred by user direction to the goal-level `release-hardening` change and are not represented as passing here.

## Architecture/API

The Round 4 architecture/API review approved the implementation with zero unresolved findings. No remediation was required in that dimension.

## Correctness and Testing

### NW-LSS-IMPL-R4-CT-001 — same-coordinator recovery could duplicate durable device rows

- `ViewerStoreCoordinator.recoverSession` now returns immediately when the connection already has durable state and clears only nondurable recovery state.
- `materializeSession` returns the existing `DeviceContext` for an already-materialized connection identifier.
- `testSameCoordinatorRecoveryDoesNotDuplicateDurableLiveDevices` repeatedly retries and recovers a mixed durable/nondurable session and proves exactly two device rows remain, with both latest lifecycle versions closed.

### NW-LSS-IMPL-R4-CT-002 — metadata and annotation quota admission raced Event writes

- `ViewerStoreMaintenance.capacityCheckedWrite` now performs the authoritative quota projection, available-capacity guard, transaction body, commit, and state reporting on the single writer executor.
- Recording metadata and annotation writes use that path, including one bounded maintenance retry and explicit available/capacity-paused reporting.
- `testConcurrentMetadataAndEventCapacityAdmissionUsesWriterOrdering` covers concurrent annotation/annotation, annotation/Event, and metadata/Event admission, including eligible-history cleanup and protected-history capacity pause.

### NW-LSS-IMPL-R4-CT-003 — invalid structural input could trigger maintenance before validation

- Structural observations are validated before quota planning, cleanup, or mutation. Validation covers monotonic-time conversion, sequence ranges, policy collection bounds, positive drop counts, gap count/time/direction/range consistency, and bounded reasons.
- `testInvalidStructuralObservationsCannotTriggerCapacityCleanup` exercises invalid policy, drop, and gap variants and proves tombstones and quota remain unchanged.

### NW-LSS-IMPL-R4-CT-004 — impossible maximum-length trailing-dot Event prefix was accepted

- The query compiler accepts a trailing-dot prefix only when the complete prefix remains below the 128-byte Event-type ceiling.
- The boundary regression accepts a 126-byte type plus dot, rejects a 127-byte type plus dot, and preserves valid 127-byte and 128-byte partial-prefix behavior.

## Security, Performance, and Documentation

### NW-ISPD4-001 — unconditional maintenance reserve created a 41 MiB no-work dead zone

- Maintenance now derives an action-specific disk plan: tombstone selection reserves only candidate bookkeeping; reclaim reserves the exact selected plan; phase/isolation work reserves its bounded plan; checkpoint and free-page inspection use zero planned bytes until actual work exists.
- `testIncrementalVacuumUsesFloorOnlyAndMeasuresPhysicalReclaim` proves no-work inspection is admitted at the 64 MiB floor, one incremental-vacuum turn reduces the freelist and page count, and one byte below the floor fails before mutation.
- Operator documentation now distinguishes SQLite page reclamation from immediate APFS allocated-byte reduction.

### NW-ISPD4-002 — structural and received-event carriers could expose content through reflection

- `WireReceivedEvent`, `ViewerDownlinkJournalEvent`, and `ViewerStructuralObservation` now provide content-free custom reflection and safe descriptions.
- A table-driven regression interpolates and reflects every carrier using a secret marker and proves the marker is absent.

### NW-ISPD4-003 — live Application Support and incremental-vacuum evidence was incomplete

- The opt-in `testOptInLiveApplicationSupportArtifactsWhileViewerStoreIsOpen` validates the actual `~/Library/Application Support/NearWire` directory and live main/WAL/SHM files while the Viewer store is open.
- A reversible audit isolated the pre-existing directory, ran the opt-in test, launched the built Viewer, verified its open file descriptors with `lsof`, quit normally, inspected the clean-close artifacts, and restored the original directory exactly. Exact measurements are recorded in `resource-filesystem-audit-round5.md`.
- The incremental-vacuum regression records both SQLite reclamation (`freelist_count` and `page_count`) and filesystem sizes. On the audited APFS volume, SQLite pages were reclaimed while the main-file logical and allocated size did not immediately shrink; the evidence and documentation state that limitation directly.

## Additional regression discovered during remediation

The complete Viewer suite exposed a transient late-runtime flush failure during shutdown. Shutdown now performs exactly one finite retry only when the first ingress flush returns `writeFailed`, then closes. The late-runtime regression passed five consecutive iterations, preserving bounded shutdown ownership without introducing a retry loop.

## Result

All seven actionable Round 4 findings are remediated. The final current-tree regressions are recorded in `implementation-validation-round5.md`; fresh independent Round 5 review remains the completion gate.
