# Change: Fix Timeline follow intent and Performance trend rendering

## Why

The Timeline currently infers its bottom state from a lazily materialized tail marker. On macOS, that marker can retain stale geometry after the operator scrolls upward, so a later Event is mistaken for a tail-follow case and forces the reading position back to the bottom.

Performance projection now publishes bounded points efficiently, but an empty display bucket is treated as a discontinuity. With normal one-second sampling and a range divided into many display buckets, nearly every measurement becomes an isolated segment. The chart therefore renders as disconnected dots rather than a readable trend.

## What Changes

- Track Timeline bottom state from actual scroll geometry on supported macOS versions, with the existing bounded fallback on older systems.
- Preserve the operator's tail-follow intent across content-height growth and never re-enable it merely because a new Event arrives.
- Connect Performance measurements across empty aggregation buckets when no explicit continuity, availability, or gap signal requires a break.
- Render the min/max envelope as a smooth translucent band with a stronger average line and subtle point markers.
- Add focused state, projection, rendering, and interaction coverage.

## Impact

- Operators reading older Events remain at their chosen position as new Events arrive.
- Performance charts present continuous trends for normal periodic sampling while still breaking at real gaps or invalid/unavailable transitions.
- Memory, publication, accessibility, and macOS 13 compatibility bounds remain unchanged.
