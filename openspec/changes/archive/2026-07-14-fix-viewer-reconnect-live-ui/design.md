## Context

NearWire accepts a TLS connection before the App Hello supplies the logical correlation tuple. The Viewer manager currently reserves one owner per tuple and rejects any later exact match. Network path changes can leave the old handle alive long enough for the new TLS connection to be rejected even though it is the same running App attempting to reconnect.

The Event Explorer renders data from a durable Store lane and a bounded live projection lane. Ordinary refresh currently runs the same destructive preparation used for scope replacement. Durable/live reconciliation normally maps a Store device-session row back to a live connection, but that materialization can lag the first durable page. The root SwiftUI view observes the application model but not its nested analysis coordinator.

## Goals and Non-Goals

Goals:

- Make an exact-route reconnect succeed without waiting for predecessor cleanup.
- Keep session ownership and cleanup finite under reconnect churn.
- Keep Event rows stable during ordinary refresh and show one representation of an Event once its durable row is visible.
- Make mode changes immediately visible and make every filter field usable in a bounded sheet.

Non-goals:

- Authenticate peer-declared installation or Bundle identifiers.
- Transfer pending downlink work, capabilities, sequence state, or session epochs between connections.
- Add automatic SDK reconnect, change discovery, or alter TLS.
- Redesign Event Explorer information architecture or add new filter dimensions.

## Decisions

### Exact-route replacement is newest-session-wins, not identity authentication

The manager will attach the new paused session to its admission core before changing route ownership. Attachment occurs outside the manager lock. Only a successful attachment may atomically replace the route owner; attachment failure leaves the current owner and any recent row unchanged. After commit, the displaced session loses control capability immediately, is assigned a replacement terminal category, and is cancelled outside the manager lock. The new connection gets a new capability, queues, epoch, and protocol state.

The route remains an unauthenticated correlation hint. Replacement is an availability policy available only after the peer has completed the same pairing/TLS admission as any other connection; it is not proof that the new peer is the old process. The Viewer will document this residual risk.

At most 16 current route owners and at most 16 displaced cleanup owners may exist. A route with an outstanding displaced cleanup cannot be replaced again until that cleanup completes. This prevents rapid reconnect churn from creating unbounded cleanup tasks. Shutdown joins both current and displaced owners.

### Ordinary refresh retains presentation

Scope, filter, materialization, Store replacement, Pause/Resume, and Jump to Latest keep their existing generation replacement behavior. Only the cadence-driven ordinary refresh retains the current Event and gap windows while releasing the predecessor traversal. The successor durable page and live evaluation replace their respective lanes atomically. A lane that is unavailable in the successor inputs is explicitly replaced with an empty lane so stale rows cannot survive.

Selection remains only when the exact identity is still resident after replacement. Loading/failure guidance may change without clearing the previous bounded rows.

An in-flight durable detail request belongs to its presentation generation. If ordinary refresh invalidates that request, the controller cancels it and waits until a successor lane confirms the exact selection is still resident before reloading. If selection disappears or changes, inspector detail, causality, renderer state, and canonical content clear together. A ready inspector for an unchanged exact identity may remain visible.

Refresh failure finalization reconciles against the presentation that is actually resident at failure time. A still-resident exact selection regains reload authority; a selection removed by a partially completed successor is cleared with its detail and scroll ownership before failure guidance publishes.

### Durable visibility can use the matching live observation as a bridge

Journal identity remains `(runtime, connection, direction, wire sequence)` and peer Event UUID remains content, not the durable key. When a durable row lacks a current materialization mapping, reconciliation may match its Event UUID to exactly one currently visible transient candidate and verify the invariant committed fields available in both presentations. It then uses that transient candidate's already-established journal key to publish durable visibility. Ambiguous or inconsistent matches do not reconcile.

This bridge does not classify duplicates, write Store state, infer delivery, or make Event UUID globally authoritative. The composite journal and Store remain the duplicate authorities.

### SwiftUI observes the owner of mode state

A dedicated analysis workspace view receives the `ViewerAnalysisModeCoordinator` as `@ObservedObject`. Picker actions still call the coordinator's serialized transition methods; the view simply observes the coordinator that owns `mode`, guidance, and revision. The root application model does not mirror or duplicate those fields.

### Filter layout uses explicit sections

The filter sheet will use a `ScrollView` and grouped sections with explicit labels, control widths, and vertical spacing. It will not use `Form`'s automatic two-column label alignment around custom multi-line controls. Existing validation, focus, draft, Apply, Clear, and Cancel behavior remains unchanged.

### Pagination triggers are single-flight per lane

SwiftUI may deliver repeated `onAppear` callbacks for the same boundary row before the first page callback completes. Event and gap pagination will therefore admit at most one request per lane at a time. A repeated boundary callback is ignored while that lane owns an active operation; after completion, the next callback may use the successor cursor. Scope replacement and shutdown keep their existing explicit cancellation behavior.

This avoids racing an already-refreshed query lease with the predecessor cursor. It does not cache pages, broaden the resident window, or hide a genuine Store failure returned by the admitted request.

## Risks and Mitigations

- A paired peer that guesses or learns another App's unauthenticated route can replace it. The pairing/TLS boundary remains mandatory, the UI never describes route replacement as authentication, and no old queue or capability transfers.
- Reconnect churn could retain cleanup work. Separate displaced ownership is capped and one outstanding displacement per route is allowed.
- Candidate attachment could fail after route inspection. Attachment happens before ownership commit, so failure changes no predecessor ownership or capability.
- Retained rows could become stale when a successor lane is absent. The coordinator explicitly clears absent lanes before marking refresh complete.
- Detail work could become stale across a retained refresh. Generation change cancels a pending load; successor residency either reloads the exact identity or clears the inspector.
- Event UUID collision could hide a distinct Event. The bridge requires exactly one transient candidate plus matching immutable presentation fields; ambiguity fails closed and leaves both rows visible with diagnostics rather than silently merging.
- Repeated row appearance could previously invalidate a traversal. Single-flight lane admission ignores only redundant requests while one exact lane operation is active; genuine completion failures remain visible.

## Verification

- Unit tests cover exact-route takeover, distinct-route capacity, queue/capability isolation, cleanup bounds, and shutdown.
- Event Explorer tests cover materialization-lag reconciliation, ambiguity rejection, non-destructive refresh, absent-lane clearing, single-flight pagination, and immediate mode publication.
- Viewer unit tests and the macOS application build run under Xcode 16.
- A launched Viewer is inspected with a focused screenshot of the Event/Performance workspace and filter sheet; the connected iPhone path is exercised when the attached device is available.
