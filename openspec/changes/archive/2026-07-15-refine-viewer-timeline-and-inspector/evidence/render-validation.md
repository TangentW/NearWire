# Render Validation

The focused Timeline test rendered the production SwiftUI components offscreen in English and retained the screenshots as XCTest attachments.

## Timeline Row

Evidence:

```text
render-attachments-round-3/26F97F40-A13F-43DB-A26C-5A1B22ED2999.png
```

Inspection result:

- Event type and exceptional `Gap` badge share the first horizontal line.
- Viewer receive time is aligned to the trailing edge of that same line.
- The content summary is the only second-level content and occupies at most three lines.
- The fourth-line overflow is visibly tail-truncated.
- Device/source, direction, priority, byte count, and a normal `consumerAccepted` badge are absent.

## Timeline and Preview Workspace

Evidence:

```text
render-attachments-round-3/91B707E2-1B51-4DD1-83EA-1F39465994FE.png
```

Inspection result:

- The Inspector exposes `Preview` instead of `Renderer`.
- Ordinary Generic JSON shows the selected Event's formatted content rather than an empty instruction.
- The offscreen macOS `List` host does not materialize row cells without a window; therefore the production row itself was rendered separately above instead of changing the production List for test convenience.

The offscreen macOS `List` cannot provide reliable interactive scrolling evidence. Instead, the focused test exercises the production frame-against-viewport state reducer used by the SwiftUI preference wiring: it verifies at-tail, scrolled-away, return-to-tail, unmounted, and stale-report rejection decisions. The controller portion separately verifies that a new Event preserves manual reading and Jump to Latest restores following. No claim is made that the offscreen screenshot itself proves scroll interaction.

## Narrow Header

Evidence:

```text
render-attachments-round-3/003E8F15-4674-4C7C-99A1-352B3467CC73.png
```

Inspection result:

- At 340 points, the Event type middle-truncates while retaining its place on the header line.
- Five exceptional states collapse to the fixed-size `+5` badge instead of wrapping.
- Viewer receive time remains visible on the trailing edge of the same line.
- The explicit accessibility label continues to name each exceptional state.
