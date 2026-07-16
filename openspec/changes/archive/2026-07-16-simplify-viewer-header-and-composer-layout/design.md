# Design

## Compact header

The pairing header keeps the connection title, pairing/listener status, workspace controls, Copy,
Refresh, Pause/Resume, and approval toggle. The two always-visible explanatory captions are removed.
The leading connection group presents a compact `Pairing Code` label, a larger monospaced code, its
listener state, and the Copy, Refresh, and Pause/Resume actions. The approval toggle moves to the
trailing side of the same row. Performance and panel-visibility controls move to the trailing side
of the title row so longer English and recovery content cannot compete with every tool in one
horizontal line. Connection actions are shown only while a pairing code is available. The
underlying security model and its documentation remain unchanged.

## Fixed Composer region

`ViewerWorkspaceVisibility.composer` defaults to `false`. The toolbar button remains the only
visibility control and keeps the existing draft/controller state when Composer is hidden.

The analysis workspace changes from `VSplitView` to a zero-spacing `VStack`. Analysis occupies all
remaining height. When Composer is visible, a normal divider and a 240-point fixed Composer region
are appended below it. The fixed value matches the existing Composer content minimum, and removing
the two header captions frees enough height for the maintained minimum window to retain the analysis
minimum.

The outer vertical `ScrollView` is removed. Composer owns bounded internal scrolling regions.
Validation feedback can shrink the flexible JSON editor to its maintained interactive minimum, and
send state plus result rows share one bounded action-column scroll region. The complete horizontal
form therefore remains usable as dynamic feedback appears, while the operator cannot drag its
height.

## Verification

- Verify default workspace state hides Composer.
- Render an explicitly expanded Composer at maintained sizes and assert exact fixed height.
- Assert the main workspace has no horizontal-divider `NSSplitView` for Composer resizing.
- Verify every native Composer text editor lies within the Composer frame.
- Verify the two removed captions do not materialize in the header.
- Verify the pairing label, code, connection actions, and approval setting share the compact header
  row without clipping at the maintained minimum width.
- Run Viewer tests, build, screenshots, strict validation, and independent review rounds.
