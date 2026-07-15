## Why

The Event Timeline currently repeats technical metadata that already belongs in the Inspector, while its existing `autoFollow` flag does not observe the actual scroll viewport or keep a tail-following operator at the newest Event. The Inspector also exposes a Tree tab that is no longer useful, renders generic Events as an empty Renderer explanation, and deliberately prevents selection and copying in Raw and Pretty content.

## What Changes

- Simplify each Timeline row to a top metadata line where Event type, exceptional diagnostic badges, and receive time share the same horizontal level, followed by a content summary of at most three lines. Device/source, direction, priority, and payload size remain available in Event metadata rather than repeating on every row.
- Track whether the Timeline viewport is at its bottom. New Events scroll to the newest row only while the operator remains at the bottom; manual upward scrolling preserves the current reading position, and Jump to Latest resumes tail following.
- Remove the Inspector Tree tab and keep the already-removed Causality tab absent.
- Make Raw and Pretty content wrap within the Inspector and support explicit text selection, Copy, and Select All while remaining read-only and non-draggable.
- Replace the empty Generic JSON Renderer state with a useful bounded preview. Specialized log, table, numeric-series, and timeline presentations remain available.

## Capabilities

### Modified Capabilities

- `viewer-event-explorer-control`: refine Timeline presentation and viewport-owned tail following, simplify Inspector tabs, permit explicit Inspector copy actions, and provide a meaningful generic renderer fallback.

## Impact

This change affects only the macOS Viewer Event Timeline, Event Inspector, renderer preparation, localization, and focused Viewer tests. It does not change Event bytes, wire protocol, SDK APIs, pairing, TLS, Session retention, filtering semantics, payload limits, or Performance behavior.
