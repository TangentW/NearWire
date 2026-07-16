# Change: Stop Timeline momentum when an Event appends

## Why

After the operator releases a Timeline scroll gesture, macOS continues delivering momentum wheel
events while the List decelerates. If a new Event changes the Timeline content during that phase,
the momentum sequence and repeated List geometry updates compete for the visible origin. The
Timeline can flash several times before settling.

## What Changes

- Observe momentum-wheel phases for the exact Timeline scroll view.
- When a new last Event arrives during momentum deceleration, retain the current visible origin and
  discard the remaining momentum sequence through its terminal phase.
- Preserve the existing rule that an operator reading above the bottom is not moved to the tail.
- Do not affect ordinary wheel gestures, other scroll views, Event capture, or Event publication.

## Impact

- A new Event no longer causes repeated flashing while Timeline inertia is settling.
- Momentum ends immediately at the current reading position when content appends.
- Networking, Event ordering, filtering, selection, and tail-follow semantics are unchanged.
