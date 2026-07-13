# Pre-Review Round 2 Remediation

Date: 2026-07-13

Round 2 confirmed every Round 1 issue resolved and identified two boundary contradictions plus one export-order race during final review.

## Oversize Reclamation

Normal physical reclaim remains bounded to 1,024 rows or 4 MiB. If the reclaim head is one legal oversize Event, one-record Event-plus-FTS reclaim may use a hard 41-MiB quota reservation. This matches the maximum `2 * 20 MiB + 1 KiB` quota formula rounded upward. An impossible larger row fails safely and cannot permanently block later tombstones.

## Export Disclosure Ownership

This change now owns operator documentation and bounded export-preflight disclosure metadata. It states that aliases are pseudonyms rather than redaction, Event/App content may identify secrets or people, output is unencrypted and outside Viewer quota/retention, and destination providers may sync or back it up. The actual selection/confirmation UI remains consistently assigned to `viewer-event-explorer-control`.

## Export Base-Row Snapshot Bounds

Export freezes AUTOINCREMENT row-ID upper bounds for base device sessions and installation aliases in addition to every append-only/version table. Stable logical device/installation ordinals are used only as alias display values. A structurally queued lower ordinal committed after lease capture therefore cannot enter later export pages.

## Additional Boundedness Refinements

- Recording and device mutable state uses append-only version tables with frozen upper version IDs.
- Maintenance performs one mutation per turn and at most eight turns per trigger.
- Orphan reconciliation processes at most 32 rows per transaction and eight turns before networking falls back to a nondurable context.
- Query/export compiler plans must use covering time/row-ID order and reject supported plans that require unbounded temporary Event/metadata sorts.

## Architecture Follow-Up

- Uplink durable identity now uses `(recordingID, deviceSessionID, direction, wireSequence)`. Peer Event UUID is explicitly nonunique content and cannot ambiguously target a later disposition transition.
- Reconciliation processes exactly one prior recording group per transaction: at most 16 child device interruption versions first, then the parent version in the same commit. Cleanup cannot select an unreconciled parent between the at-most-eight group turns.
- Export alias names are unambiguous: `device-N` identifies one logical installation across reconnects, while `connection-N` identifies one exact device-session row.

Validation:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
git diff --check
```

Both passed with no validation or whitespace diagnostics.
