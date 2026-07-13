# Task 6.8 Operator Documentation Evidence

Date: 2026-07-13

## Published guide

`Documentation/Viewer-Event-Explorer.md` is the English operator and engineering guide for the
native three-column Event Explorer and memory-only control composer. It documents:

- authoritative Viewer receive-time ordering and the separate App-created/monotonic values;
- exact live-to-durable reconciliation, partial source/device materialization, `Not recorded`
  behavior, and the bounded duplicate horizon;
- gap, drop, conflict, session, full-text-outage, and incomplete-history semantics without a
  completeness or exactly-once claim;
- Pause versus acquisition, latest-only 10-Hz refresh, paging, resident caps, work limits, and
  fixed refine behavior;
- Generic/log/table/numeric renderer bounds, fallback, raw chunks, structured control and
  bidirectional escaping, causality ambiguity, and accessibility boundaries;
- revision-safe history operations, frozen complete/filtered export, atomic destination, and the
  complete unencrypted/pseudonym/sensitive-content/external-retention/sync disclosure;
- composer content/TTL/target bounds, normal and keep-latest policies, per-target local admission,
  and the exact limit of `Queued locally` wording;
- schema-1-to-2 status, disk preflight/floor, once-per-process automatic attempt, explicit retry,
  rollback, and continued bounded live operation while durable services are unavailable;
- deterministic accounting versus Swift heap, structural release gates versus diagnostic machine
  timing, privacy, clipboard, joined cleanup, fresh-runtime content absence, and V1 exclusions.

The root and Viewer READMEs link the guide. The local-store and multi-device documents now describe
their current Event Explorer integration rather than leaving the implemented UI described only as
future work.

## Validation

```text
git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid

wc -l Documentation/Viewer-Event-Explorer.md
# 351 Documentation/Viewer-Event-Explorer.md
```

A targeted heading/term inspection covered receive time, transient state, materialization,
duplicates, gaps, FTS exclusion, Pause, resident/work bounds, renderers, escaping, causality, TTL,
local queue admission, export disclosure, schema recovery, accounting, diagnostics, privacy,
cleanup, and exclusions. All links use repository-relative Markdown targets that exist in
`Documentation`.
