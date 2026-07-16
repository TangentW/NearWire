# Spec-to-Evidence Audit

## Byte-budget-only retention

- Production evidence: `ViewerLiveEventDeque.insert` evicts only when the incoming accounted bytes exceed the remaining 32 MiB budget.
- Capacity evidence: `maximumByteDerivedEventSlots` is exactly `retainedBytes / fixedEntryOverheadBytes`, so its 1,024 slots represent every byte-valid retained Event set.
- Test evidence: 600 minimum-size Events remain without count-triggered gaps; two half-window Events cause oldest-first byte eviction; the 100,000-offer bounded-drain test passes.

## Complete Timeline publication and stable tail behavior

- Production evidence: `ViewerEventExplorerController` assigns the complete matched successor instead of taking a fixed suffix; `ViewerExplorerLimits.maximumEventRows` was removed.
- Test evidence: the Explorer publishes all 600 ordered rows; the existing tail-follow test confirms that manual upward reading remains stable and Jump to Latest restores following.

## Import, replacement, evaluation, and pending metadata

- Production evidence: import, replacement, evaluator, deque, conflict markers, authority, and pending metadata use the appropriate byte-derived retained or retained-plus-ingress defensive capacities.
- Test evidence: a 600-Event complete-Session JSON file imports successfully; evaluator over-shape behavior remains bounded; the blocked-executor saturation regression covers 1,024 retained plus 64 ingress keys and verifies successor dispositions and conflicts.

## Documentation and compatibility

- `Viewer-Memory-Session.md` and `Viewer-Event-Explorer.md` describe byte-budget retention without an independent Event-count/row limit.
- The final Viewer build passed in Swift 5 language mode with the existing strict-concurrency setting and macOS 13 deployment target.

## Completion

- Focused and class-level tests, source scan, build, `git diff --check`, and strict OpenSpec validation passed as recorded in `implementation-validation.md`.
- Two independent review rounds are recorded; all round-one findings were fixed and round two is clean.
