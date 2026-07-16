# Change: Stabilize Timeline tail presentation and default panel split

## Why

The Timeline currently inserts a transparent synthetic `List` row as its scroll target. The row still participates in macOS list layout, so a newly appended Event can appear at the bottom and then move upward when the deferred scroll reveals the synthetic tail.

The Event workspace also gives Timeline and Inspector similar ideal widths. Timeline carries the denser scanning workflow and should receive most of the initial horizontal space.

## What Changes

- Remove the synthetic Timeline tail row and scroll directly to the last real Event identity.
- Attach the macOS 13/14 fallback tail measurement to the last real Event row without changing macOS 15+ scroll-geometry behavior.
- Default the two visible Event panels to approximately 70% Timeline and 30% Inspector while preserving minimum widths, divider dragging, and independent panel visibility.
- Add focused interaction and rendered-layout coverage.

## Impact

- A following Timeline presents a new Event directly in its final position without a transient blank row or second visual shift.
- Operators receive a more useful default scanning layout and may still resize or hide either panel.
- Event ordering, selection, filtering, transport, retention, and public SDK behavior are unchanged.
