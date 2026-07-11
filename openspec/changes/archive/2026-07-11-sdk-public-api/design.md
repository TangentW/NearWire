## Context

Core can validate Codable event content, bound queues, and describe eventual wire events. The supported SDK cannot expose those modules because CocoaPods compiles Core into the same module while SwiftPM exposes separate implementation modules, and either integration must present the same source-level API. The next discovery/session change also needs a facade-owned place to retain offline events and publish inbound work without turning a connection coordinator into application API.

Important constraints are:

- The SDK supports iOS 16+, Xcode 16+, Swift 5 language mode, modern concurrency, SwiftPM, and CocoaPods.
- `NearWire` is an instance, not a singleton. Construction starts no network, timer, task, disk, Keychain, or UI work.
- An application may create multiple instances, but a later process-wide connection lease will allow only one active connection attempt/session.
- Events require a type and JSON-compatible content. Generic Codable APIs use ISO-8601 UTC dates, Base64 data, finite numbers, and deterministic Core validation.
- `.normal` keeps every admitted item. `.keepLatest` replaces an older pending item with the same caller-supplied key.
- Send completion in this change reports only local admission. It never implies transmission, receipt, acknowledgement, or persistence.
- The App owns bounded in-memory uplink work while disconnected. Discovery and live connection orchestration are deliberately absent; only the synchronous handoff into the already-established secure channel is added.
- Async streams must support more than one observer without an unbounded continuation buffer or hidden global publisher.

## Goals / Non-Goals

**Goals:**

- Establish a small, idiomatic public API entirely in the `NearWire` module.
- Make generic Codable send, receive decode, and causal reply operations straightforward.
- Retain pending events in a bounded actor-owned queue before a session exists.
- Give callers exact local admission, replacement, expiration, and overflow information.
- Expose current state plus bounded state and incoming-event AsyncSequence subscriptions.
- Finish streams and reject mutation after explicit shutdown.
- Provide internal, actor-isolated seams that the next session coordinator can use without widening the supported API.
- Prove SwiftPM and CocoaPods consumers compile the same public surface.

**Non-Goals:**

- A public connect, disconnect, pairing-code, discovery, trust, or Viewer selection API.
- Bonjour browsing, Network.framework connection work, TLS identity decisions, handshake, sequence allocation, rate negotiation, or retry.
- Incoming rate limiting or session-driven scheduling; the later session owns negotiated downlink scheduling before publishing to the facade.
- Disk persistence, delivery acknowledgements, exactly-once delivery, cross-launch buffering, or automatic background execution.
- Objective-C callbacks, delegates, Combine, global registries, or a singleton.

## Decisions

### 1. Make `NearWire` an actor with a side-effect-free public initializer

`public actor NearWire` owns mutable SDK state and the offline queue. Its initializer validates no dynamic environment and starts no work. The supplied `NearWireConfiguration` is an immutable value that was validated when constructed. Each instance owns independent queue, state, diagnostics, and stream hubs.

The public lifecycle in this change consists of observation, sending while offline, and idempotent `shutdown()`. Connection methods arrive only when the next change can make them real. This avoids a public `connect` method that necessarily fails or secretly does nothing.

### 2. Keep supported signatures in the NearWire module

Public signatures use Foundation values or NearWire-owned types only. Internal conversion extensions translate public content, priorities, TTL, policies, IDs, and errors to Core/flow-control values. No public declaration names `NearWireCore`, `NearWireFlowControl`, `NearWireTransport`, `JSONValue`, `EventDraft`, `EventEnvelope`, or `BoundedEventQueue`.

This is required for source equivalence because CocoaPods places Core and SDK files in one module while SwiftPM compiles them as dependencies.

### 3. Expose JSON-shaped event content without requiring type erasure

`NearWireEventContent` is a Sendable, Equatable JSON-shaped enum with null, Boolean, signed integer, finite double, string, array, and object cases. It is inspectable without decoding into an application type. Conversion from generic Encodable values and back to generic Decodable values always goes through Core's deterministic `EventContentCodec`.

The public event contains its stable UUID, validated type string, content, priority, local creation date, direction, and optional correlation/reply IDs. Session epoch, wire sequence, endpoints, and receive timestamps are not invented offline and remain session/Viewer details.

### 4. Use explicit send options and local-admission results

`NearWireEventOptions` contains priority and optional TTL. A separate `NearWireSendPolicy` argument is either `.normal` or `.keepLatest(key:)`; keep-latest does not implicitly use the event type because independent state series may share a type. The key is local queue metadata and is not transmitted.

`send(type:content:options:)` encodes and validates content, constructs a collision-checked stable event ID and local creation time, calculates a deterministic accounted byte count from the internal draft representation, and attempts queue admission. The returned `NearWireSendResult` reports whether the new event remains buffered plus any coalesced, expired, or overflow-dropped IDs. Its terminology never says delivered or received.

An incoming `NearWireEvent` has `reply(type:content:options:)` support through `NearWire.reply(to:...)`, which carries the source event ID as both correlation and reply-to metadata. The facade attaches a hidden origin-instance token and Viewer/session route affinity. It rejects an event produced by another instance, and internal drain drops a pending reply if the active Viewer identity or session epoch differs. A normal new send has no route affinity. Public configuration also carries separate App-local uplink and downlink rate caps; the defaults are 100 and 50 events per second, and the later session computes the conservative result with the Viewer request.

### 5. Map errors to stable codes and safe fields

`NearWireError` exposes a stable code, optional safe field, and fixed English message. It never forwards `localizedDescription` from application Codable implementations or internal transport/security errors. Invalid configuration fails at public configuration construction. Send and decode failures throw supported SDK errors.

The SDK distinguishes invalid event type, invalid content, encoding/decoding failure, invalid options, event too large, queue failure, stream overflow, and shutdown. Error text is diagnostic, not a localization contract.

### 6. Reuse Core's bounded queue behind the actor

The actor stores internal queued event records in `BoundedEventQueue`. Public buffer limits map once to validated Core limits. The default remains 1,000 events, 4 MiB total, and 256 KiB per accounted event.

The accounting codec deterministically encodes the complete internal draft using sorted JSON keys. Queue limits therefore apply to a stable SDK admission representation, not an estimate of a later encrypted frame. The wire layer still enforces its independent frame maximum.

TTL uses a local monotonic enqueue timestamp. Wall-clock `createdAt` is presentation metadata only. Queue snapshots expire due work using the same injected monotonic clock and return NearWire-owned diagnostics. Overflow follows Core's priority-aware eviction contract, so local admission can succeed while the incoming low-priority event is immediately evicted.

### 7. Give the future session actor narrow internal queue seams

Internal actor methods can publish a validated incoming envelope, update public state, and drain bounded outbound candidates through a synchronous transport-admission closure. They are not public SPI and are tested through same-module SDK tests.

One actor call offers a bounded sequence of fair queue candidates, drops replies whose route affinity does not match, and stops on the first transport rejection. Route-affinity validation is a local preflight before transport byte-budget evaluation, so even a stale reply larger than the current batch can be removed without consuming transport bytes or blocking later eligible work. The secure channel exposes a synchronous, lock-protected mailbox admission operation: success means the channel owns the encoded bytes within its count and byte limits. Only successful candidates are removed and charged transport bytes. A rejected candidate and the unattempted remainder never leave their queue positions, so FIFO, keep-latest ordinals, TTL, and public clear/diagnostics remain exact. Bytes already accepted by transport are beyond the clear boundary.

Encoding precedes mailbox admission for each candidate. If the session cannot yet produce bytes, the drain reports that exact candidate as not attempted, leaves it in place, and does not increment transport-rejection telemetry. The future session coordinator must treat that result as a session decision point rather than immediately spinning on the same head candidate; its negotiated-size and terminal encoding policy remains in the session change.

The next session change owns when to invoke this drain, when to allocate session sequence, how to encode before synchronous channel admission, and how to negotiate rates. This change does not start timers or remove events merely because a state changes.

### 8. Use bounded fan-out hubs for AsyncSequence observation

Each `states` subscription receives the current state first and then changes. State subscriptions keep only the newest pending state because intermediate UI snapshots are superseded.

Each `events` subscription has a validated finite capacity. If a subscriber cannot keep up, the hub terminates only that subscription with `NearWireError.streamOverflow`; it does not silently drop an event, block the facade actor, disconnect the session, or affect other subscribers. Hubs remove terminated continuations and perform no user callback while holding their lock.

Explicit shutdown transitions once to `.shutdown`, clears offline work, publishes the final state, finishes all streams, and rejects later sends/replies. A stream requested after shutdown is immediately terminal, with the state stream still yielding the final shutdown snapshot first.

### 9. Keep network state vocabulary future-compatible

`NearWireState` can represent idle, connecting, connected, reconnecting, disconnected, and shutdown phases with safe optional diagnostics. Only idle and shutdown are publicly driven in this change. Internal state publication is available for the next session coordinator. No state embeds transport errors, endpoints, certificates, or Core values.

### 10. Test public behavior without clocks, sleeps, or network

An internal initializer accepts deterministic wall-clock, monotonic-clock, and UUID suppliers. Tests cover encoding, decoding, validation, queue boundaries, coalescing, TTL, priority overflow, multiple instances, multiple stream observers, slow-consumer overflow, cancellation cleanup, and shutdown races without sleeping.

Consumer fixtures compile against `import NearWire` through both SwiftPM and a CocoaPods-generated workspace. Boundary scripts also reject supported signatures that expose implementation modules.

All top-level Core declarations use the `NearWireInternal` SPI. Repository-owned targets import it explicitly; a normal CocoaPods `import NearWire` cannot name those declarations even though CocoaPods uses one compilation module. A separate `NearWireBuiltins` SPI exposes only platform-event admission so optional targets such as `NearWirePerformance` can send reserved event types through the facade without gaining the complete Core surface.

## Risks / Trade-offs

- **[Risk] Public content mirrors Core JSON values** -> Keep conversion exhaustive and add round-trip/property-style coverage for every case and nested structures.
- **[Risk] Actor calls make send asynchronous even when only buffering** -> This matches future session isolation and gives one race-free ordering boundary.
- **[Risk] Slow event observers terminate instead of losing data** -> Use a typed overflow error and let callers resubscribe; silent loss would make debugging timelines misleading.
- **[Risk] Queue admission bytes differ from wire bytes** -> Document the exact SDK accounting boundary and retain independent wire frame validation.
- **[Risk] A send result is misread as delivery** -> Use `isBuffered` and local-effect names only, and document all excluded guarantees.
- **[Risk] Internal session seams become accidental API** -> Keep them internal, test public symbol boundaries, and allow the next change to revise them before external adoption.
- **[Risk] Shutdown clearing surprises a caller** -> Make shutdown explicit and terminal, return no false delivery result, and document that offline memory never persists across lifecycle end or process exit.

## Migration Plan

1. Add public SDK value models, validation, conversion, and safe error mapping.
2. Add the actor facade, bounded queue ownership, transactional queue offering, synchronous secure-mailbox admission, internal session seams, and fan-out hubs.
3. Add deterministic SDK unit tests, public API consumer fixtures, and English API documentation.
4. Run package, pod, simulator, macOS, strict-concurrency, boundary, English, and OpenSpec gates.
5. Complete independent remediation to zero findings, archive, and commit before discovery/session apply begins.

Rollback is a normal commit revert because no shipped application, persisted format, network session, or Viewer project consumes this API yet.

## Open Questions

None. Public connection methods, pairing-code validation, active-session ownership, negotiated downlink rate limiting, reconnect policy, and background transitions are intentionally deferred to `sdk-discovery-session`.
