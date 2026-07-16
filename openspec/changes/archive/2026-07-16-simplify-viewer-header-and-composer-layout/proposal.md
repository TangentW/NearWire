# Change: Simplify the Viewer header and Composer layout

## Why

The main header permanently shows two explanatory security/discovery captions that repeat product
documentation and consume vertical workspace. The bottom Viewer-to-App Composer also starts
expanded inside a resizable vertical split. At the maintained window size, the split can allocate
less height than the Composer's designed content height, so controls appear clipped and the
operator can resize the region into an incomplete state.

## What Changes

- Remove the two persistent transport/discovery caption rows from the main header.
- Present a larger pairing code with a compact `Pairing Code` label, keep Copy, Refresh, and
  Pause/Resume beside it on the leading side, and move approval to the trailing side of the same
  header row.
- Default the Viewer-to-App Composer to collapsed.
- When expanded, render the Composer at one fixed 240-point height that matches its complete
  horizontal content layout.
- Replace the resizable vertical split with a stable stacked layout so the operator cannot resize
  the Composer height.
- Preserve the existing Composer visibility toolbar control, draft state, send behavior, and
  single-window Event workspace.

## Impact

- The initial Viewer gives more vertical space to Event analysis.
- Opening Composer reveals its full intended form without a draggable height divider.
- Security, pairing, TLS, Bonjour, transport, and SDK behavior are unchanged.
