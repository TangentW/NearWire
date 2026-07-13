# Pre-Implementation Review Remediation — Round 4

## Status

Round-4 security/performance/documentation approved the first revised artifact snapshot. During the
same round, correctness/testing identified three additional testability/wording gaps before issuing
its report. The normative artifacts were tightened, which invalidated the earlier same-round
approval for final gate purposes; fresh reviews are required against the current snapshot.

No production or test source was modified.

## Migration connection transition

The migration writer is now explicitly migration-only. After commit or rollback it closes and the
executor joins until every sorter descriptor is gone. Success opens a fresh writer through the
normal hardening path with `temp_store=MEMORY` and an explicit 8-MiB cache target, reprobes schema,
features, indexes/plans, and settings, then opens two equally normal fresh readers. Availability is
published only after those probes. A failed post-open probe closes the fresh connections. Tasks 2.1
and 6.1 require exact construction-order, configuration, close/join, and failure evidence so FILE
temp and the migration-only 32-MiB cache cannot leak into runtime use.

## Duplicate comparator conformance tests

Task 3.2 now names the same durable-projection comparator as the two normative capabilities plus
initial disposition; session metadata, deterministic accounting, and later Viewer receive times are
excluded. Task 6.3 now requires metadata/accounting/receive-time-only and same-normalized-millisecond
differences to remain equal, preservation of the first values, stored-projection/disposition
differences to conflict, pre-journal session-invariant rejection, and no hash-only decision across
pending, drain, eviction, `untracked`, durable, recovery, and shutdown states. This makes both the
former live/store metadata mismatch and the current durable receive-time comparison deterministic
test failures.

## Actual macOS clipboard controls

Task 6.4 now exercises the real macOS text controls, keyboard commands, and contextual commands, not
only model methods. Operator-owned inputs permit bounded copy/cut/paste; received/stored Event
inspector controls expose no copy/cut/drag/share/clipboard-export command; no background pasteboard
read occurs. Tasks 5.5 and 6.4 explicitly preserve the separate disclosed JSON file-export workflow,
so the clipboard prohibition cannot be misread as disabling required file export.

## Validation

- Strict OpenSpec validation: exit 0.
- `git diff --check`: exit 0.
- No production or test source changed.

The artifact gate remains blocked until one fresh common snapshot receives zero-finding approval in
all three review dimensions.
