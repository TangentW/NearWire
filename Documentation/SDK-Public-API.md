# NearWire SDK Public API

## Supported Boundary

The primary SDK is the `NearWire` module. It supports iOS 16 or later, Xcode 16 or later, Swift 5 language mode, Swift Package Manager, and CocoaPods. Its supported signatures use only Foundation and supported types declared by the NearWire module. Core event, flow-control, wire, pre-handshake codec and typed result, admitted-message, transport, Network.framework, and Security.framework values are hidden behind the repository-only `NearWireInternal` SPI or module-internal boundaries, including when CocoaPods compiles Core and SDK sources into one module.

The SDK uses Swift concurrency. It does not provide a singleton, delegate API, Combine publisher, NotificationCenter contract, or Objective-C compatibility layer.

The supported facade includes one explicit `connect(code:)` attempt. It does not yet expose disconnect, automatic reconnection, background policy, or lifecycle observation. Construction does not start connection work early.

## Create an Instance

Each application chooses when to create and retain its own instance:

```swift
import NearWire

let buffer = try NearWireBufferConfiguration(
  maximumEventCount: 1_000,
  maximumBytes: 4 * 1_024 * 1_024,
  maximumEventBytes: 256 * 1_024,
  defaultTTL: .seconds(60)
)

let configuration = try NearWireConfiguration(
  maximumUplinkEventsPerSecond: 100,
  maximumDownlinkEventsPerSecond: 50,
  buffer: buffer,
  eventStreamBufferCapacity: 256
)

let nearWire = NearWire(configuration: configuration)
```

The two directional rates are App-local maximums. An active session computes each effective rate as the minimum of this value and the Viewer request. Zero pauses that business-event direction. The default App-local caps are 100 uplink and 50 downlink events per second.

Initialization allocates small in-memory state only. It does not start discovery, request local-network permission, open a connection, claim process connection ownership, launch a task or timer, access disk or Keychain, or create UI. Multiple idle instances are independent. An explicit connection attempt claims one process-wide connection lease; a second instance receives a typed contention error rather than replacing the owner.

## Connect Explicitly

```swift
do {
  try await nearWire.connect(code: "ABC234")
} catch let error as NearWireError {
  // Branch on error.code. Messages are fixed engineering diagnostics.
}
```

The code uses the same bounded six-character normalization as Viewer discovery. It is a discovery and admission selector, not a password or certificate credential. NearWire does not persist it or retain it for retry.

One call performs one attempt: it claims process ownership, loads the device-local installation identifier, discovers the matching Viewer through peer-to-peer-enabled Bonjour, establishes mandatory TLS 1.3, completes hello approval, and activates the first conservative flow policy. Success means that active transport is ready. It does not mean that any Event was received, persisted, processed, or acknowledged.

The installation identifier is a canonical random UUID stored as a generic-password item in the data-protection Keychain. It uses `WhenUnlockedThisDeviceOnly`, does not synchronize or migrate to another device, and cannot prompt for authentication. NearWire never overwrites or deletes the item and currently provides no reset API. The identifier lets a Viewer correlate one App installation; it is not a secret or an authentication credential.

The App hello also includes the compiled NearWire version and, when valid String values exist, the host bundle identifier, short version or build fallback, and display name or bundle-name fallback. Invalid or non-String property-list values are omitted rather than stringified.

Only one attempt or active session may belong to one `NearWire` instance. A second call returns `connectionInProgress` or `alreadyConnected`. The process lease also prevents a different NearWire instance from connecting concurrently. Cancelling the connect Task requests cancellation but does not release ownership until current non-cancellable work or permanent session cleanup reaches its exact terminal boundary.

## Send Codable Events

Event types are dot-separated ASCII segments. Each segment starts with a letter and may continue with letters, digits, `_`, or `-`. Application event types cannot use the reserved `nearwire` namespace.

```swift
struct RouteChanged: Codable, Sendable {
  let route: String
}

let result = try await nearWire.send(
  type: "ui.route.changed",
  content: RouteChanged(route: "/checkout"),
  policy: .keepLatest(key: "current-route"),
  options: NearWireEventOptions(
    priority: .normal,
    ttl: .seconds(30)
  )
)
```

Content is encoded as validated JSON. Dates use ISO-8601 UTC text with fractional seconds, Data uses Base64, object keys are deterministic, integers must fit in signed 64-bit range, and floating-point values must be finite.

The V1 policies are:

- `.normal`: retain each admitted event as an independent item.
- `.keepLatest(key:)`: replace an older pending item that uses the same explicit queue-local key.

The keep-latest key is not sent to the Viewer. It lets one event type carry several independently coalesced state series.

Repository-owned optional modules use a separate narrow `NearWireBuiltins` SPI to enqueue reserved `nearwire.*` event types through this same queue. A normal application import cannot use the reserved namespace, and the SPI is not a supported application API.

`NearWireSendResult` reports local effects only: the event ID, local enqueue date, whether the new item remains buffered, and IDs coalesced, expired, or dropped by overflow. A successful call does not mean bytes were transmitted, the Viewer received the event, the Viewer processed it, or the event was persisted.

## Offline Memory Buffer

App-to-Viewer events can be sent while the instance is idle and later while discovery, connection, or reconnection is in progress. They remain only in memory.

Defaults are 1,000 pending events, 4 MiB total accounted bytes, 256 KiB for one accounted event, and a 60-second TTL. The SDK calculates a deterministic internal draft representation for queue accounting. Encrypted frame size is validated independently by the wire and transport layers.

TTL uses an instance-local monotonic clock. A wall-clock change does not expire or extend work. When capacity is exceeded, the queue removes the oldest item from the lowest priority present. A newly submitted low-priority event may therefore be the item dropped immediately when the queue already protects higher-priority work.

Inspect or clear the queue explicitly:

```swift
let diagnostics = try await nearWire.bufferDiagnostics()
print(diagnostics.eventCount, diagnostics.accountedByteCount)

let cleared = await nearWire.clearBufferedEvents()
print(cleared.removedEventIDs)
```

Statistics distinguish application `submitted` calls, events synchronously `transportAccepted`, and actual `transportAdmissionRejected` attempts. Offering a candidate does not manufacture another submission, and stopping before admission counts only the one candidate actually rejected. Expiration, coalescing, overflow, explicit clearing, and route-affinity drops have separate counters.

The buffer is not a database. It does not survive process exit or `shutdown()`, and it provides no acknowledgement, retry, at-least-once, or exactly-once guarantee.

## Receive and Decode Events

Incoming events are exposed as an `AsyncThrowingStream`:

```swift
struct FeatureFlagOverride: Codable {
  let name: String
  let enabled: Bool
}

for try await event in nearWire.events {
  switch event.type {
  case "feature.flag.override":
    let command = try event.decode(FeatureFlagOverride.self)
    await apply(command)
  default:
    break
  }
}
```

`NearWireEventContent` also exposes the content as null, Boolean, signed integer, finite number, string, array, or object cases for generic inspection. An incoming event contains its ID, type, content, creation date, priority, direction, causality, and NearWire-owned session metadata.

Each event subscriber has the configured finite buffer. If a subscriber cannot keep up, only that subscription finishes with `NearWireError.Code.streamOverflow`. NearWire never silently drops an event from that subscriber's stream, block the facade actor, or terminate other subscribers. The caller can resubscribe after handling the error.

Replying is a convenience around normal sending:

```swift
let result = try await nearWire.reply(
  to: request,
  type: "debug.snapshot.response",
  content: snapshot
)
```

The reply gets a new event ID and uses the request ID as both `correlationID` and `replyToEventID`. This does not add request timeouts, acknowledgement, or delivery guarantees.

Replies are bound internally to the NearWire instance, Viewer identity, and session epoch that produced the source event. Passing an event from another NearWire instance fails with `invalidReply`. If a reply is still pending after the active route changes, the SDK drops it before transport admission and increments `routingDropped`; it never sends a reply to a different Viewer or session. Route validation runs before the transport batch byte budget, so an oversized stale reply cannot block later eligible work.

The active session drains events through one actor-isolated admission operation. Events are removed only when the secure transport's bounded mailbox synchronously accepts their encoded bytes. If transport backpressure rejects a candidate, it and the unattempted remainder stay in their original queue positions; FIFO, scheduler credit, IDs, and TTL are unchanged. Consequently there is no hidden, long-lived reservation outside `bufferDiagnostics()` or `clearBufferedEvents()`. Bytes already accepted by transport are beyond the buffer clear boundary.

If a session cannot produce encoded bytes for the candidate, the internal drain reports it as not attempted, leaves it pending, and does not increment `transportAdmissionRejected`. The session coordinator resolves that session-level condition instead of immediately retrying the same queue head.

## Observe State

Each state subscription immediately receives the current value and then later changes:

```swift
for await state in nearWire.states {
  // idle, discovering, connecting, connected, disconnected, shutdown
}
```

State streams retain only the latest pending state because an intermediate UI snapshot is superseded by a newer one. Cancelling one subscription does not disconnect or shut down the instance. One public attempt drives `discovering`, `connecting`, and `connected`; a pre-success failure after discovery or any post-success terminal condition drives `disconnected`. `reconnecting` remains source-compatible but is not emitted by this implementation.

## Shutdown

```swift
await nearWire.shutdown()
```

Shutdown is idempotent and terminal. It detaches the exact public connection owner, requests cancellation, clears pending in-memory App events, publishes the final shutdown state, finishes existing streams, and rejects later sends, replies, and connects with `NearWireError.Code.shutdown`. Internal terminal cleanup may continue long enough to close a session and release the process lease safely. A state stream created afterward yields `shutdown` once and finishes. An event stream created afterward finishes immediately.

Releasing an instance also releases its local observers and memory. Applications should call `shutdown()` when they need the explicit terminal state and deterministic clearing behavior.

## Safe Errors

`NearWireError` contains a stable code, an optional safe field, and a fixed English diagnostic message. It does not forward arbitrary `localizedDescription` text from application Codable implementations, transport failures, certificate data, endpoint data, pairing codes, or event content.

Connection-specific codes distinguish invalid code, same-instance overlap, process contention or unavailable ownership, Task cancellation, discovery timeout or denial, ambiguous discovery, connection timeout, secure transport failure, incompatible or rejected Viewer, identity mismatch, remote close, and a closed internal-failure fallback. Failures after `connect` has already returned are represented only by the `disconnected` state; there is no terminal-error history API.

The message is intended for engineering diagnostics, not as a localized user-interface contract. Applications should branch on `code`.

## Explicit Non-Guarantees

The SDK facade does not itself provide persistence, delivery acknowledgement, RPC semantics, retry, at-least-once delivery, exactly-once delivery, background execution, automatic enablement, reconnection, or pre-established Viewer authentication. The current TLS policy prevents plaintext transport but intentionally permits normal Viewer switching without certificate pinning. Persistence remains a Viewer concern.
