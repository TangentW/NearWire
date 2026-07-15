## Why

The Viewer still exposes the storage-oriented Sources and recorded-session catalog even though the intended product is now one working Session for the lifetime of the Viewer process. That left column consumes substantial space, separates Devices from the connection controls that give them context, and makes the Viewer feel like a history browser instead of a live event workbench.

The Event workspace also lacks direct actions to clear the current Session or collapse its major regions. Ordinary Event arrival still invalidates broader SwiftUI view trees than necessary, which can make split views and inspector content appear to flicker even when their semantic state did not change.

## What Changes

- Replace the Sources-and-Devices sidebar with a compact Devices strip below the connection header. The Viewer exposes exactly one current working Session and no historical Source selector.
- Back that working Session with process-scoped local storage used only for bounded query, filter, export, and performance analysis. It is not reopened as Viewer history on a later launch.
- Preserve Session JSON export and add bounded, validated JSON import. Import replaces the empty current working Session only while no App is active or awaiting approval.
- Add a confirmed Clear action to Event Timeline. Clear removes the current Session's Events, Event dispositions, gaps, drops, annotations, and derived performance inputs while preserving listener state and connected Devices.
- Add Xcode-style top controls that independently show or hide Event Timeline, Event Inspector, and the bottom Viewer-to-App composer.
- Isolate SwiftUI invalidation by semantic region, preserve split-view identity, coalesce high-frequency presentation publication, and disable implicit animation for data-only Event updates.
- Add model, store, import/export, UI-rendering, accessibility, and performance-regression coverage.

## Capabilities

### Modified Capabilities

- `viewer-application-foundation`: the single-window Viewer owns one process-scoped working Session and a top Devices/workspace-control area instead of a Sources sidebar.
- `viewer-local-store-search`: storage is an ephemeral single-workspace query engine with atomic Clear and validated Session import/export rather than a persistent recording history.
- `viewer-event-explorer-control`: the Explorer has current-Session-only scope, a destructive Clear action, collapsible regions, and region-scoped SwiftUI publication.
- `viewer-performance-dashboard`: Performance analysis follows the same one-Session clear/import generation and does not retain stale chart state.

## Impact

The change affects the native macOS Viewer application model, Store lifecycle and explorer gateway, JSON transfer services, Event/Performance controllers, SwiftUI layout, documentation, and Viewer tests. It does not change the wire protocol, TLS policy, Bonjour discovery, SDK public API, package products, entitlements, or third-party dependencies.
