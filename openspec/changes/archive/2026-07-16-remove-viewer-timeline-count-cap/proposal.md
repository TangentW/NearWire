# Change: Remove the fixed Timeline Event-count cap

## Why

The Viewer currently applies a fixed 512-Event retention cap and then applies the same fixed suffix cap again while publishing Timeline rows. This can discard many small Events even though the existing 32 MiB memory budget still has room, and it makes the Timeline appear artificially limited.

## What Changes

- Remove the fixed Event-count condition from current-Session retention and Timeline row publication.
- Keep the existing 32 MiB deterministic Event-memory budget as the authoritative retention boundary.
- Size internal fixed storage from the byte budget and minimum accounted per-Event overhead so memory remains finite without exposing an independent product count limit.
- Allow JSON import and closed filter evaluation to accept every Event that fits the same byte-derived current-Session capacity.
- Preserve oldest-first eviction, gap diagnostics, selection reconciliation, and viewport-based tail following.

## Impact

- Small Events can remain visible beyond the former 512-row ceiling.
- Large Events continue to evict older content when the 32 MiB budget is exhausted.
- There is no unbounded process-memory growth and no database or persistence change.
