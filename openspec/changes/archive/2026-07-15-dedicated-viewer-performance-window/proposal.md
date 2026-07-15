## Why

Events and Performance currently replace each other inside one segmented Analysis pane. That makes the main Timeline and Inspector disappear while the operator studies charts, and it leaves the top Timeline/Inspector visibility controls disabled and meaningless in Performance mode. It also prevents the operator from keeping raw Events visible while comparing performance trends.

Performance is a distinct, longer-lived analysis task and fits a dedicated macOS window better than a tab-like mode. A visual-only move is insufficient because the current coordinator deactivates Event traversal and clears Inspector state before Performance work starts.

## What Changes

- Keep the main Viewer window permanently focused on the Event Timeline, Event Inspector, Devices, and Viewer-to-App composer; remove the Events/Performance segmented control.
- Add a labeled Performance button that opens or focuses one singleton Performance window.
- Give the Performance window its own accessible single-Device selection without changing the main Event Device filter, plus its existing range, pause, cards, charts, availability, and raw-Event actions.
- Allow Event and Performance presentations to remain active together through one bounded Store gateway and one serialized operation queue, with at most one retained Event traversal and one retained Performance traversal.
- Make raw-Event reveal focus the main window, restore Inspector visibility, and select the exact Event without closing or resetting the Performance window.
- Tie the runtime to the application lifetime rather than the main-window lifetime so either supported window can remain open safely.
- Add focused lifecycle, traversal, selection, layout, accessibility, rendering, and regression coverage.

## Capabilities

### Modified Capabilities

- `viewer-application-foundation`: the native Viewer has one main Event window and one singleton auxiliary Performance window under one application/runtime lifetime.
- `viewer-event-explorer-control`: Events remain visible and interactive while Performance owns its independent Device scope and bounded traversal.
- `viewer-performance-dashboard`: Performance becomes an independent window, preserves its non-content selection controls in-process, and reveals raw Events into the main window without mode switching.
- `viewer-multidevice-flow-control`: Event multi-selection and Performance single-selection are distinct views over the same Device/session authority.

## Impact

The change affects the macOS SwiftUI Scene graph, Event/Performance coordination, the Viewer Store explorer arbiter, application lifecycle, performance selection presentation, documentation, and Viewer tests. It does not change SDK APIs, wire messages, transport, TLS, Bonjour, storage schema, import/export format, package products, entitlements, or third-party dependencies.
