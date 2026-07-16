# Spec-to-evidence audit

## Stable initial allocation

- Production applies the initial divider position once from the configured 70% Timeline fraction.
- Delayed render tests inspect minimum, standard, and wide workspaces after layout settles.
- The dedicated split test verifies the ratio remains 70/30 through content and locale updates.

## Operator resizing and minimum widths

- The native `NSSplitView` divider remains interactive.
- Delegate constraints preserve Timeline and Inspector minimum widths.
- Tests move the divider to both invalid extremes and verify each clamp.
- Tests move the divider to an operator-selected position and verify later updates do not reset it.

## Visibility and lifecycle

- The split remains mounted while at least one Event panel is visible.
- Hiding one panel preserves the split and surviving hosting-view identity.
- The hidden hosting graph is removed and weakly verified as released.
- Restoring the peer recreates only that peer and reapplies the saved divider fraction.
- Static single-panel tests verify the visible panel fills the available width.

## Environment, build, and quality

- Locale and color scheme are forwarded into hosted SwiftUI roots.
- Dynamic en → zh-Hans → en locale updates are verified by a direct environment probe.
- ViewerFoundationTests passed with 99 passed, 0 failed, and 1 skipped.
- Viewer build passed.
- Strict OpenSpec validation and diff check passed.
- Light and dark screenshots were inspected.
- Three independent review rounds ended with no unresolved findings.

Every changed requirement and scenario has matching production behavior and validation evidence. No
SDK, transport, Event model, storage, or public API behavior changed.
