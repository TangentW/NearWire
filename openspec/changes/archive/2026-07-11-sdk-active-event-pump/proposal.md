## Why

NearWire can return one internally admitted TLS session, but that session remains in policy negotiation: Event frames are rejected, the App queue is not drained, incoming events are not published, and no negotiated rate is enforced. The next SDK layer must activate that same route without replacing its channel or decoder and must keep all queue, sequence, rate, backpressure, and terminal behavior bounded.

## What Changes

- Add one internal, explicitly run active-event-pump starter for an attached admitted session; construction remains side-effect-free, activation returns an explicit lifetime handle plus non-owning terminal observation, and second-run or pre-run cancellation is deterministic.
- Negotiate the Viewer-requested directional flow policy against the App-local maxima, acknowledge the effective values, support bounded dynamic offers, and activate Event transfer only through that policy transition.
- Extend the permanent session core into active state without retargeting callbacks or replacing the secure channel, frame decoder, negotiated codec, route, or cancellation relay; owner binding uses one continuous deadline and a pause-aware terminal-preemptible ingress handshake.
- Drain the existing NearWire uplink queue only after synchronous reserved-capacity transport admission, admit no more Events than a captured whole-token allowance, allocate App-to-Viewer sequence values only for accepted bytes, preserve route-affinity drops, and retry mailbox backpressure without polling or long-lived reservation.
- Decode single and batched Viewer events, validate exact route and contiguous sequence, establish receiver-local TTL deadlines, buffer them under explicit count/byte bounds, rate-limit publication, and terminate rather than silently overflow.
- Add level-triggered owner availability, coalesced outbound-work wakeups, and one-shot token-or-TTL decision wakeups so shutdown cannot be lost, an idle active session owns no recurring poll timer, and paused work still expires on time.
- Keep the supported SDK API, products, targets, pod subspecs, dependencies, entitlements, privacy declarations, public state, process lease, reconnection, persistence, lifecycle observation, UI, and performance collection unchanged.

## Capabilities

### New Capabilities

- `sdk-active-event-pump`: Internal policy activation, bidirectional Event transfer, route/sequence/TTL enforcement, rate scheduling, bounded buffering, backpressure, cancellation, ownership, and safe terminal behavior for one admitted SDK session.

### Modified Capabilities

- `sdk-session-admission`: The attached admitted owner can transfer its existing permanent core into one explicitly run active pump with a continuous binding/policy deadline and pause-aware terminal-preemptible callback ingress while preserving decoder, channel, relay, and terminal authority.
- `sdk-offline-buffer`: The internal session seam adds owner-aware exact wire encoding, captured-token-bounded accepted prefixes, coalesced outbound wake registration, and retry-safe transport backpressure while preserving queue and telemetry semantics.
- `sdk-public-boundary`: Repository-owned active-pump work may transfer Events internally, but no supported connect/disconnect or active-pump API is exposed and ordinary public operations still start no session work.
- `secure-byte-channel`: Event-lane mailbox admission can reserve bounded count and bytes for Control traffic while retaining the existing linearized FIFO and no-partial-admission guarantees.
- `bounded-event-queue`: Queue scheduling observation exposes the next origin-local expiration deadline so a paused uplink can expire work with one one-shot wake rather than polling.
- `event-rate-control`: An internal prevalidated token commit lets the active SDK install an accepted prefix without a new throwing calculation after peer-visible mailbox admission.

## Impact

The change affects internal SDK session, queue-integration, and test-support code plus a narrow Core transport mailbox extension. It adds no third-party dependency or supported application API. It prepares the admitted session for the later `sdk-public-connect` orchestrator but does not claim the process lease, publish connection state, reconnect, observe App lifecycle, or expose connection controls.
