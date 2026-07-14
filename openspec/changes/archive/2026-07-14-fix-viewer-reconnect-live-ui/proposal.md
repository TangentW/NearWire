## Why

The Viewer currently rejects a second secure connection that declares the same App installation and Bundle identifiers while the first connection is still owned. A phone that changes from LAN discovery to the peer-to-peer path can therefore complete TLS but still fail with the generic secure-connection error because its prior route has not finished cleanup.

The live analysis workspace also has four presentation defects: mode changes are not observed until unrelated model activity occurs, ordinary refresh clears and rebuilds the timeline, transient and durable representations of one committed Event can overlap while Store materialization catches up, and the filter editor relies on a macOS `Form` layout that collapses its custom fields. Repeated SwiftUI row-appearance callbacks can additionally submit the same pagination cursor more than once; the later request then observes a refreshed Store lease and surfaces a misleading bounded-view warning.

## What Changes

- Replace an exact logical route's currently owned session with the newest successfully handed-off secure session, while keeping replacement cleanup bounded and never transferring queues, capabilities, epochs, or delivery claims.
- Preserve the visible Event timeline during an ordinary refresh and replace each durable/live lane atomically when successor results arrive.
- Reconcile a visible durable row with its exact transient observation even when the Store-to-live device materialization is temporarily unavailable, without changing durable identity or duplicate-authority rules.
- Coalesce repeated Event or gap pagination triggers while one request for that lane is still in flight, preserving the current query lease and suppressing spurious invalid-request warnings.
- Make the SwiftUI analysis content directly observe the analysis-mode coordinator so Events/Performance switching redraws immediately.
- Replace the filter sheet's automatic `Form` layout with explicit scrollable grouped sections sized for macOS.
- Add regression coverage and focused build/UI evidence for the reported behavior.

## Capabilities

### Modified Capabilities

- `viewer-multidevice-flow-control`: an exact route reconnect replaces the prior owned session under bounded cleanup instead of being rejected.
- `viewer-event-explorer-control`: live/durable reconciliation and ordinary refresh produce one stable timeline, and the filter editor has a bounded usable layout.
- `viewer-performance-dashboard`: mode publication is immediately observed by the workspace while existing arbiter handoff ordering remains authoritative.

## Impact

The change affects only the native macOS Viewer manager, analysis presentation, Event Explorer model/coordinator, SwiftUI views, and Viewer tests. It changes no wire format, TLS policy, SDK public API, discovery behavior, package product, entitlement, persistence schema, or third-party dependency.
