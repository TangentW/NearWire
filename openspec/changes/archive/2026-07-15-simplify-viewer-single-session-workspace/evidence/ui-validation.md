# UI Validation Evidence

## Live application inspection

The signed Debug Viewer was relaunched from `/tmp/nearwire-viewer-layout-fix/Build/Products/Debug/NearWire.app` after the final responsive-layout fix and inspected through macOS accessibility automation.

- The top Devices strip appears directly below connection controls and no Sources sidebar is present.
- Timeline, Inspector, and Viewer-to-App Composer buttons expose explicit Expanded accessibility values in the running app.
- The active state uses both a checkmark and styling, so it does not rely on color alone.
- The standard dark window keeps the Event Timeline toolbar below the Analysis header and above the Composer divider. The Composer becomes vertically scrollable when compressed, and every control remains exposed in the accessibility tree.

Saved full-window screenshots:

- `screenshots/viewer-standard-dark.jpeg`

An intermediate differential accessibility capture was discarded because it did not contain a complete window and was not valid visual evidence.

## Deterministic render coverage

`testRunningWorkspaceRendersAtSupportedSizesAndAppearances` rendered the running workspace at:

- minimum: 1000 x 720;
- standard: 1280 x 800; and
- wide: 1440 x 900.

Each size rendered in Aqua and Dark Aqua. All six images were retained as XCTest attachments in `/tmp/nearwire-viewer-single-session-final-6/Logs/Test/Test-NearWireViewer-2026.07.15_15-01-33-+0800.xcresult`.

The test also resolves invisible layout probes for Analysis, the Timeline toolbar, and the Composer viewport. Across all six variants it verifies the 260-point Analysis minimum, Timeline containment within Analysis, the 180-to-360-point Composer viewport, containment inside the host window, and no Analysis-to-Composer or Timeline-to-Composer intersection.

`testFilterSheetRendersExpandedControlsWithinMinimumBounds` also passed and retained its expanded Filters attachment. The test checks editor width, vertical separation, scrollable bounds, and the full control inventory.

## Event-arrival stability

The UI uses semantic presentation signatures for the root, Devices, Timeline, Inspector, Filters, and Performance regions. Equivalent high-frequency controller revisions do not publish those regions. Timeline rows use stable Event identities, data-only list updates disable implicit animation, and filter controls no longer observe every Event revision.
