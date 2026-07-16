# Design

## Stable native divider position

SwiftUI `HSplitView` does not expose a divider-position binding. A temporary child `maxWidth`
constraint can force the first frame, but releasing that constraint allows the split view to
redistribute equally.

The two-panel workspace will use a small macOS-native split representable backed by `NSSplitView`.
It hosts the existing Timeline and Inspector SwiftUI views, applies the 70/30 divider position once
after the split has a non-zero width, and does not reapply it during ordinary updates. Native
divider interaction therefore remains authoritative after initialization.

The split delegate constrains the divider to the maintained Timeline and Inspector minimum widths
and prevents panel collapse. The representable remains mounted while at least one Event panel is
visible. Hiding a panel removes only that panel's arranged hosting view, so the surviving panel keeps
the same hosting identity and expands across the split. The hidden hosting graph is released so it
cannot continue observing high-frequency Event updates. Restoring the peer creates only that panel's
hosting view and reapplies the last operator divider fraction.

## Stable updates

Updating Timeline or Inspector content replaces only the corresponding hosting controller root
view. It does not recreate the `NSSplitView` or reset the divider. The representable also avoids
asynchronous state mutation from SwiftUI rendering. The parent locale and color scheme are
explicitly forwarded into both hosted SwiftUI roots.

## Verification

- Render the two-panel workspace, allow delayed main-actor and layout work to settle, and assert the
  ratio remains approximately 70/30.
- Trigger a normal root-view update and assert the divider does not return to 50/50.
- Move the native divider in the hosted test and verify it remains movable within both panel
  minimums.
- Re-run single-panel expansion, Viewer tests, Viewer build, strict OpenSpec validation, screenshots,
  and independent review rounds.
