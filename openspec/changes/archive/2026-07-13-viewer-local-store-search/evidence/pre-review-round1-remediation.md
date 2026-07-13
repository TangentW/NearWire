# Pre-Review Round 1 Remediation

Date: 2026-07-13

The first architecture/API, correctness/testing, and security/performance/documentation reviews reported overlapping lifecycle, snapshot, capacity, disposition, and resource-bound findings. No production or test source was modified. The artifacts were revised as follows.

## Durable Lifecycle

- Added stable logical recording/device contexts independent of SQLite availability.
- Made durable parent/device/Event guarantees conditional on causal admission.
- Defined unavailable-start, partial mid-runtime retry, ended-during-outage gap behavior, reserved structural capacity, idempotent lifecycle revisions, and next-open orphan reconciliation.

This resolves architecture finding 1 and correctness finding 3.

## Read Connections, Cancellation, Pagination, and Export

- Replaced the single-connection model with one writer, one interactive reader, and one export reader, each on its own serial executor.
- Added generation-bound interrupt/progress cancellation, short read transactions, per-page VM/time budgets, eight finite query leases, and one finite export lease.
- Made Events and membership-changing transitions/samples append-only with frozen per-table upper IDs and nonreused AUTOINCREMENT IDs.
- Cleanup/manual deletion skip leased recordings; query/export never hold a long WAL snapshot.
- Replaced the unbounded alias map with stored recording-local installation/device ordinals and paged device metadata.

This resolves architecture finding 2, security findings 2 and 3, and correctness findings 5 and 6.

## Quota and Bounded Cleanup

- Defined deterministic schema-owned quota reservations separately from reported physical SQLite sidecar footprint.
- Added a volume-available-capacity safety floor and removed the false physical-overshoot claim.
- Replaced unbounded whole-session cascades with an atomic whole-recording tombstone followed by 1,024-row/4-MiB physical reclaim transactions.
- Bounded one maintenance campaign to eight turns and 32 logical selections per turn, with one task plus one dirty successor.
- Defined exact 85% and 100% exhaustion outcomes, protected/leased behavior, checkpoint failure, and logical-deletion versus secure-erasure semantics.

This resolves architecture finding 3, security finding 1, and correctness findings 2 and 4.

## Event Disposition and Protocol-Executor Work

- Replaced the impossible one-shot final uplink disposition with an immutable Event commit plus one append-only idempotent terminal transition.
- Added consumer-accepted, expired, overflow-displaced, and session-ended outcomes plus gap semantics when a transition cannot be stored.
- Required precomputed deterministic byte accounting and copy-on-write value admission; canonical JSON and all linear content work occur only on the writer executor.
- Raised default ingress to 4,096/32 MiB and added one-record oversize transactions up to 20 MiB so every current legal Viewer Event has a coherent path.

This resolves architecture finding 4, security finding 5, and correctness findings 1 and 2.

## Filesystem, Text Operators, and Disclosure

- Extended owner-only regular nonsymlink policy to the Application Support directory and main/WAL/SHM/journal/migration/export-temporary artifacts.
- Selected `secure_delete=ON` as defense in depth and documented that retention does not guarantee erasure from WAL, snapshots, or backups.
- Defined literal FTS quoting, NUL/control rejection, NFC search normalization, binary `substr` Event-type prefix, and `instr` JSON containment instead of wildcard `LIKE` semantics.
- Added exact recording-name and note/annotation limits.
- Required export disclosure that aliases are pseudonyms, not redaction; output is unencrypted and outside Viewer quota/retention and may be synced/backed up.

This resolves security findings 4, 6, and 7.

## Validation

Commands:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
git diff --check
```

Results: strict OpenSpec validation passed and `git diff --check` produced no output.
