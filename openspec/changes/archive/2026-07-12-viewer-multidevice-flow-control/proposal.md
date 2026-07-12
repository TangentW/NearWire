## Why

The Viewer can now advertise, accept, and safely hand off one negotiated App connection, but the foundation deliberately closes every accepted handoff. NearWire therefore has no long-lived Viewer session, no one-to-many device model, no Viewer-side flow-policy authority, and no bidirectional Event path. This change turns the existing handoff seam into the first bounded multi-device workspace while preserving the permanent connection owner and protocol implementation already proven by the foundation and SDK changes.

## What Changes

- Replace the foundation placeholder handoff consumer with a Viewer-owned multi-device session manager that bounds every mixture of provisional, negotiating, active, and disconnecting App owners to 16 through exact cleanup while preserving the admission layer's separate 32-owner safety bound.
- Extend the immutable admission connection core in place so its existing callback and continuous frame decoder can complete hello acknowledgement, initial flow-policy negotiation, active Event transfer, dynamic policy updates, and terminal cleanup. Add narrow platform-neutral internal Core seams for bounded decoder pause/resume and one generation-bound secure-channel receive-pause token, allowing valid coalesced input to yield without eager receive rearming or wire changes.
- Give each active connection a fresh session epoch and validate every active message against the negotiated protocol, route, source, target, sequence, epoch, payload size, and receiver-local TTL rules.
- Make Viewer authoritative for requested App uplink and App downlink rates. Resolve each new session from a per-session override, bounded Bundle-ID preference, or global default; activate only the most conservative accepted values and serialize later policy updates.
- Add bounded per-session uplink-delivery and downlink-send queues, normal and keep-latest downlink behavior, token-bucket rate control, 500 ms batching, bounded control-mailbox reservation, local drop summaries, and queue/rate telemetry without recurring idle timers.
- Correlate devices from peer-declared App installation ID plus optional Bundle ID, label that continuity as unauthenticated, reject duplicate live claims, bind downlink work to one exact connection, support local nicknames, and keep one device's work isolated from every other device.
- Replace the empty workspace with a connected-device sidebar and a focused device detail view for session state, nickname, requested/effective rates, queue health, throughput, and Event counts.
- Persist only bounded Viewer preferences and nicknames in `UserDefaults`; keep effective policy, Event payloads, session epochs, queue contents, and reconnect state in memory.
- Add deterministic unit/integration coverage and English operator/architecture documentation. Do not add another shell test harness.

## Capabilities

### New Capabilities

- `viewer-multidevice-flow-control`: Bounded Viewer session ownership, device identity preferences, negotiated directional flow control, bidirectional in-memory Event transfer, telemetry, and the first connected-device workspace.

### Modified Capabilities

- None.

## Impact

The change affects the existing `Viewer/NearWireViewer` application and tests, internal Core framing/secure-channel receive-control seams and their tests, Viewer/Core documentation, and OpenSpec evidence. It reuses `NearWireCore`, `NearWireTransport`, and `NearWireFlowControl` through the existing root `NearWireCore` Swift package product. It introduces no third-party dependency, nested manifest, database, supported SDK API, wire-schema change, or new entitlement.
