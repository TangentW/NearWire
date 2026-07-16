# Change: Keep the Viewer default split stable

## Why

The current Viewer establishes the requested 70/30 Timeline/Inspector split with a temporary
Inspector width constraint. After a few main-actor turns, the constraint is removed so the native
divider can move. `HSplitView` then performs another layout and returns both flexible children to an
approximately equal 50/50 split.

The existing render test samples before that delayed redistribution, so it does not detect the
visible regression.

## What Changes

- Replace the temporary SwiftUI width constraint with a native split container that establishes the
  divider position once and retains it.
- Preserve native divider dragging, Timeline and Inspector minimum widths, panel visibility, and
  single-panel expansion.
- Extend layout coverage to verify the ratio after delayed layout has settled and after a normal
  content update.

## Impact

- Timeline remains at approximately 70% and Inspector at approximately 30% until the operator moves
  the divider or changes panel visibility.
- No SDK, Event, transport, storage, or public API behavior changes.
