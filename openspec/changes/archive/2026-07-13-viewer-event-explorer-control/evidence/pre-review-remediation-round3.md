# Pre-Implementation Review Remediation — Round 3

## Status

Round 3 produced two architecture findings and two security/performance/documentation findings;
the high migration-temp finding overlapped between those reports. Correctness/testing approved the
then-current artifacts, but later fixes changed normative text, so a fresh round 4 was requested in
all three dimensions.

No production or test source was modified.

## Migration temporary-storage feasibility

Resolved by removing the migration-only Application Support temp-directory contract. Local macOS
SDK evidence confirms that `sqlite3_temp_directory` is discouraged process-global legacy state and
cannot be safely toggled around one connection; NearWire therefore does not read or mutate it, the
related pragma, `SQLITE_TMPDIR`, `TMPDIR`, or install a custom VFS.

Schema-1 migration now uses system-default-VFS disk sorting only after the process-provided
sandbox/private temporary directory is verified current-user-owned, mode 0700, and nonsymlink.
Checked headroom and the 256-MiB live floor apply independently to database and temporary volumes,
once when identical. Sorters contain only the three index key sets, never Event JSON. The system VFS
owns delete-on-close; completion requires zero remaining process sorter descriptor, while crash/temp
reclamation is documented as OS logical cleanup rather than secure deletion. Tasks 2.1 and 6.1 now
prohibit global routing/VFS changes and require unsafe-root, distinct-volume, descriptor, mode,
content, cancellation, rollback, and retry evidence.

This resolves architecture round-3 High and security round-3 R3-SPD1 without adding a new VFS or
helper-process security boundary.

## Duplicate equality alignment

Resolved by using the same durable Event projection and initial disposition in live and durable
requirements, excluding newly sampled Viewer receive times, deterministic accounting, and session
invariants/metadata. Neither path trusts a hash alone. A later round-4 source-seam check refined this
projection further; see the subsequent remediation note.

## Clipboard/input boundary

Resolved by replacing the blanket clipboard prohibition with an explicit boundary. Standard
user-invoked paste/copy/cut is available only in operator-owned editable composer/filter/metadata
controls, and pasted replacements must pass the incremental cap before model storage. NearWire does
not read or monitor the pasteboard in the background, restore it, or keep custom clipboard history.
Received/stored Event inspector content has no copy, cut, drag, share, or clipboard-export command.
Tasks 5.5 and 6.4 require both the over-cap paste behavior and the received-Event prohibition. This
resolves R3-SPD2.

## Validation

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  — exit 0, `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` — exit 0 with no output.
- No production or test source changed; only the active OpenSpec directory remains untracked.

Implementation remains blocked pending fresh round-4 approval in all three dimensions.
