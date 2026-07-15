# Visual and Interaction Inspection

## Render coverage

The full Viewer XCTest result bundle at `/tmp/NearWirePerformanceFinal.xcresult` retains SwiftUI render
attachments for the Performance window at minimum and representative sizes, including light and dark
appearances, populated same-name Device choices, empty selection, preparing, failure, and
runtime-unavailable recovery states.

The UI reviewer confirmed the latest 800 by 600 light and dark populated renders were fully opaque
with alpha extrema `(255, 255)`, readable hierarchy and contrast, stable chart regions, and visible
recovery actions.

## Launched application inspection

The final signed `NearWire.app` was launched and inspected through macOS accessibility state.

Main window observations:

- Window identifier was `main`.
- A labeled `Open Performance window` button with identifier
  `nearwire.workspace.open-performance` was present.
- No Events/Performance segmented mode control was present.
- Timeline, Inspector, and Composer controls remained available.

Performance window observations:

- Clicking Performance focused a separate window with identifier `performance`.
- The toolbar exposed `Performance Device` and `Show main Viewer window` controls.
- With no connected Device, the picker was disabled with `No Devices in This Session` and fixed
  guidance remained visible.
- The range control, disabled Pause action, current cards, fixed availability rows, and chart host
  remained reachable at the inspected size.
- `Show Viewer` returned focus to Main, and the Main Performance action returned focus to the
  existing Performance window.

Raw reveal, paused reveal, same-turn close, Store replacement, close/reopen, and no-focus-on-failure
interactions were additionally exercised by deterministic coordinator and real-Store tests because no
physical App connection is required for those race checks.
