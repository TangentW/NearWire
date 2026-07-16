# Design

## Real Event tail target

The final `ViewerExplorerTimelinePresentationRow.id` becomes the scroll target. `ScrollViewProxy` receives that exact identity after the existing generation-bound yield, so coalesced arrivals cancel stale scroll requests and only the newest requested Event is revealed.

The separate transparent `List` row and its private anchor identity are removed. On macOS 15 and later, actual `ScrollGeometry` remains authoritative. On macOS 13/14, the fallback frame preference and disappearance signal are attached conditionally to the current final Event row. The existing settled-row latch preserves a legitimate append-follow transition while keeping an already false user intent false.

## Initial 70/30 split

`HSplitView` remains the native, user-resizable container. During its initial two-panel layout, Inspector receives a temporary 30% width bound while Timeline expands into the remaining 70%. After the initial layout settles, that bound is released so the native divider remains freely resizable. The existing minimum widths remain authoritative, and either surviving panel continues to expand when its peer is hidden.

Layout probes expose the materialized Timeline and Inspector frames to the existing offscreen macOS rendering tests. The initial two-panel ratio is accepted within a small tolerance for the native divider.

## Verification

- Host a populated Timeline, append a successor while following, and verify no synthetic row exists and the final Event settles at the viewport bottom without a second row-height shift.
- Re-run the existing manual-scroll regression to ensure an operator away from the bottom remains stationary.
- Render the main workspace at maintained sizes and verify the initial Timeline/Inspector width ratio is approximately 70/30 while both panels satisfy their minimum widths.
- Run Viewer tests, build, strict OpenSpec validation, and independent review rounds.
