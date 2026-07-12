## Context

The supported SDK currently owns one explicit `connect(code:)` attempt and one active session. The attempt uses an exact actor token, a shared transition gate, a process-wide lease, one admitted lifetime, and one terminal coordinator. The coordinator releases the lease before delivering a weak tokenized terminal callback. Post-return failures currently expose only `NearWireState.disconnected`, and the normalized pairing code is deliberately released because no lifecycle policy uses it.

This change must add lifecycle behavior without weakening those ownership rules. NearWire supports iOS 16, compiles in Swift 5 language mode with Xcode 16 or later, has no third-party SDK runtime dependencies, and must not assume that one `UIApplication` notification represents the host's multi-scene policy.

## Goals / Non-Goals

**Goals:**

- Give application code an explicit, idempotent disconnect that waits for exact public cleanup.
- Let the host explicitly pause and resume connection intent without automatic UIKit observation.
- Make transient recovery opt-in, bounded, cancellable, and fresh-session-only.
- Publish one latest connection status that carries a content-safe terminal reason and retry progress.
- Preserve one process owner, one active route, one terminal wait, and stale-callback isolation across replacements.

**Non-Goals:**

- Requesting iOS background execution, subscribing to lifecycle or reachability notifications, or promising background networking.
- Persisting the pairing code, retry state, Viewer identity, Events, or connection history.
- Resending transport-accepted bytes, acknowledging delivery, or deduplicating across sessions.
- Adding UI, performance collection, Viewer changes, certificate pinning, logging, or analytics.

## Decisions

### 1. Add an exact, default-disabled recovery policy API

The supported declarations are:

```swift
public struct NearWireReconnectionPolicy: Equatable, Sendable {
  public static let disabled: NearWireReconnectionPolicy
  public let isEnabled: Bool
  public let maximumAttempts: Int
  public let initialDelay: Duration
  public let maximumDelay: Duration

  public init(
    maximumAttempts: Int,
    initialDelay: Duration = .seconds(1),
    maximumDelay: Duration = .seconds(30)
  ) throws
}

public struct NearWireConfiguration: Equatable, Sendable {
  public let reconnectionPolicy: NearWireReconnectionPolicy

  public init(
    maximumUplinkEventsPerSecond: Double = 100,
    maximumDownlinkEventsPerSecond: Double = 50,
    buffer: NearWireBufferConfiguration = .default,
    eventStreamBufferCapacity: Int = 256,
    reconnectionPolicy: NearWireReconnectionPolicy = .disabled
  ) throws
}
```

The disabled value exposes `isEnabled == false`, zero attempts, and zero delays. The throwing initializer creates only an enabled policy and accepts `maximumAttempts` in `1...20`, `initialDelay` from 100 milliseconds through 60 seconds, and `maximumDelay` from `initialDelay` through 300 seconds. Validation uses exact `Duration` components, checked nanosecond conversion, and fixed fields `reconnectionPolicy.maximumAttempts`, `reconnectionPolicy.initialDelay`, and `reconnectionPolicy.maximumDelay`.

The attempt number is a total automatic-work budget owned by one connection intent. It is reset only by explicit host authority: successful initial `connect(code:)` starts with zero used attempts, and `resumeConnection()` starts a new recovery campaign. A brief recovered connection does not reset it. Before enabled-policy attempt `n`, the delay is `min(maximumDelay, initialDelay * 2^(n - 1))`, capped before multiplication. When the budget is exhausted, intent is cleared and no more work exists. The disabled policy performs no automatic attempt; an explicit resume authorizes exactly one immediate attempt and preserves intent after a transient failure so the host may explicitly choose again.

There is no jitter in V1. The intent-wide budget prevents a flapping Viewer from resetting work indefinitely, while deterministic delays keep behavior testable. Always-on, infinite, reachability-triggered, and per-interruption-reset recovery were rejected because they permit unbounded P2P work or add platform observers.

### 2. Use one actor-owned intent capsule from validation through lifecycle end

After pairing validation and before the first suspension, the actor installs one pending intent capsule containing the normalized pairing code, lifecycle generation, zero used automatic attempts, and pending phase. Admission receives a separate one-shot discovery transfer, but neither the raw method argument nor Bonjour state is later reparsed to reconstruct intent. The pending capsule authorizes no retry. Connected commit atomically promotes that same capsule to active intent without making another lifecycle copy.

Every initial failure, Task cancellation, disconnect, suspension before first connected commit, shutdown, or stale completion clears the pending capsule. After promotion, manual disconnect, permanent recovery failure, enabled-policy budget exhaustion, and shutdown clear it. Active, suspended, and disabled-policy transient-disconnected modes may retain it in memory. Explicit `connect(code:)` never supersedes an intent: the App must await `disconnect()` before entering another code.

The current attempt/active slot owns only one route. A fresh route always performs new Bonjour discovery, TLS, hello/admission, session epoch, sequence state, pump, terminal coordinator, and process-lease claim. No decoder, credit, mailbox data, accepted bytes, or old waiter crosses the boundary. Route owners, coordinators, delay Tasks, Keychain, Events, status, errors, reflection, and logs retain no pairing code. Swift String zeroization is not promised.

### 3. Keep platform policy explicit and define command precedence

The public actor methods remain:

```swift
public func disconnect() async
public func suspendConnection() async
public func resumeConnection()
```

NearWire registers no UIKit, SwiftUI scene, NotificationCenter, reachability, or background-execution observer. Suspension is a policy latch even without intent. `suspendConnection()` sets it, cancels delay or current route, and awaits the exact cleanup receipt. Suspension before initial connected commit clears the pending capsule; suspension after commit preserves active intent. `resumeConnection()` clears the latch. It may reset the recovery campaign and schedule work only for retained active intent after suspended cleanup or after a disabled-policy transient-disconnected result. The one Boolean deferred request is reserved only for resume that follows suspension and arrives before that suspended route's receipt settles. Resume while connected, during initial connect, or during any automatic/explicit recovery delay or attempt is inert: it neither resets budget nor records future work. With no intent, it performs no connection work.

`disconnect()` is the monotonic stronger operation: it clears pending/active intent, suspension, resume request, retry progress, and last error; cancels current work; and awaits cleanup. It is a connection-work no-op only when intent, slot, recovery Task, and cleanup receipt are all absent, but it may still clear status fields. Concurrent actor ordering governs suspend/resume, while a later disconnect always prevents successor work. Shutdown overrides every command. Caller Task cancellation applies only to an initial explicit connect and is lower than shutdown, disconnect, and suspension. All non-shutdown attempt cancellation completes connect with `connectionCancelled`.

Explicit connect preflight order becomes: shutdown, pre-latched Task cancellation, suspension, current initial/recovery attempt or cleanup, active route, retained intent, input validation, limit/version validation, reservation, then lease. Fixed results are shutdown, connectionCancelled, `connectionSuspended`, connectionInProgress, alreadyConnected, `connectionIntentExists`, invalidPairingCode, invalidConfiguration, then mapped lease error. A new code is therefore never timing-dependent during recovery.

### 4. Separate lifecycle authorization from exact cleanup receipts

The actor stores one lifecycle generation, optional intent capsule, suspension and resume-request bits, retry counters, status, one optional recovery Task, and one optional constant-space cleanup receipt for the current route. The receipt owns one shared `Task<Void, Never>` awaited by any number of callers; the actor stores no per-caller continuation list. Awaiting the shared Task deliberately ignores caller cancellation and returns only at the cleanup boundary.

Lifecycle generation gates intent, state, status, delay, and successor-route mutation. The exact route token separately settles its cleanup receipt once after direct release or coordinator release, even when the lifecycle generation has been invalidated. Receipt settlement occurs before stale-generation checks. No successor claim begins while an unresolved receipt exists. This lets old cleanup finish callers without authorizing old state to mutate a newer route.

The transition gate gains explicit disconnect and suspension cancellation reasons. The terminal coordinator remains the sole lifetime waiter and releases before delivery. A failed terminal wait continues to vault the lease and cannot prove release; the shared cleanup Task deliberately remains incomplete, so disconnect/suspend do not falsely return. Release enter/exit failure still settles the receipt after the exact release invocation but provides no reacquisition promise.

A recovery delay Task captures only generation, attempt number, delay, and its cancellation-completion owner. It holds no code, actor, route, endpoint, or application metadata across sleep. Production sleep is cancellation-cooperative. Invalidating commands cancel the Task and await or defer successor work until its completion acknowledgement; a held/noncooperative injected sleeper safely delays completion rather than allowing Task accumulation. Deinitialization explicitly cancels the Task.

### 5. Classify failures by closed code and lifecycle phase

The mapping input includes the exhaustive internal code and whether it arose as an active-route terminal or a pre-active recovery-attempt failure. Active-route `transportFailed`, active-route or pre-active `remoteClosed`, discovery timeout/unavailable/failure, and session timeouts are transient. Pre-active `transportFailed` is permanent because the closed code may represent repeatable TLS trust, identity, or ALPN rejection. `clockFailed` is permanent because a fresh route does not repair a local clock invariant. A pre-active valid remote close remains bounded by the intent-wide budget and is distinct from explicit Viewer rejection or protocol incompatibility.

Local configuration/encoding/ownership failures, local-network denial, ambiguous discovery, incompatible or rejected Viewer, identity mismatch, protocol/sequence/route violations, hostile-work/ingress limits, owner unavailable, and every internal invariant code are permanent. Disconnect, suspension, Task cancellation, stale generation, and shutdown are lifecycle cancellation and never recover. A new code fails exhaustive compilation or validation until assigned. Safe public mapping discards remote text, bytes, endpoint/interface, certificates, pairing code, Bundle metadata, Events, and underlying errors. No disposition weakens TLS or permits plaintext fallback.

### 6. Publish one coherent latest-value status and canonical transitions

The supported status API is:

```swift
public struct NearWireConnectionStatus: Equatable, Sendable {
  public let state: NearWireState
  public let lastError: NearWireError?
  public let reconnectAttempt: Int?
  public let isSuspended: Bool
}

public nonisolated var connectionStatuses: AsyncStream<NearWireConnectionStatus>
public var connectionStatus: NearWireConnectionStatus { get }
```

Every status subscriber first receives current value and retains only the newest pending value. One actor method updates current state and status in one turn and suppresses duplicate values. The independently buffered `states` and `connectionStatuses` streams may coalesce different intermediate publications; every status itself is coherent and `connectionStatus.state == currentState` after its actor turn.

The canonical rows are:

| Prior ownership / winner | State after boundary | Error | Attempt | Suspended | Intent |
| --- | --- | --- | --- | --- | --- |
| idle suspend | idle | nil | nil | true | none |
| suspended idle resume | idle | nil | nil | false | none |
| resume while connected / initial attempt / recovery campaign | unchanged | unchanged | unchanged | unchanged | unchanged |
| initial connect phases | discovering / connecting | nil | nil | false | pending |
| initial success | connected | nil | nil | false | active |
| initial failure/cancel | prior stable state or disconnected after discovery | thrown only | nil | current latch | none |
| active transient, disabled | disconnected | safe terminal | nil | false | active |
| active transient, enabled with budget | reconnecting | safe terminal | next total attempt | false | active |
| enabled recovery success | connected | nil | nil | false | active with used budget preserved |
| enabled permanent failure/exhaustion | disconnected | safe failure | nil | false | none |
| disabled explicit resume | reconnecting then connected/disconnected | current safe failure | 1 while current | false | preserved on transient failure |
| suspend active/recovery | disconnected after receipt | nil | nil | true | active |
| disconnect any non-shutdown mode | disconnected after receipt | nil | nil | false | none |
| shutdown | shutdown | nil | nil | false | none |

During cleanup, existing state remains until receipt settlement; suspension may already appear in status. Recovery remains reconnecting through delay, discovery, admission, and activation. Resume during cleanup is represented only by the Boolean request. Repeated resume does not reset a current campaign or create work. Manual disconnect clears a previously retained error even when state was already disconnected. Shutdown publishes one final status and finishes both hubs.

### 7. Recover only after release and never replay ambiguous bytes

After old coordinator release and receipt settlement, a generation-current active terminal may schedule recovery. Enabled-policy attempt `n` waits its exact capped delay and consumes the intent-wide budget before claim. Disabled explicit resume attempt 1 is immediate. The delay Task re-enters weakly and the actor obtains the pairing code from the authorized intent only at route construction; no Task holds it across sleep.

Recovery uses the same reviewed internal connection pipeline in a mode that keeps public state reconnecting and returns its closed result to the lifecycle controller. Success installs a fresh owner and clears public error/progress without resetting used budget. Transient failure schedules the next remaining attempt; permanent failure or exhaustion clears intent. Resume while connected, during initial connect, or during delay/attempt is inert and cannot authorize deferred work. A later explicit resume is possible only after suspended cleanup or while disabled-policy transient intent remains; bounded exhaustion requires a new explicit `connect(code:)` because its intent was cleared.

Only Events still in the offline queue are eligible on the fresh route. Bytes accepted by the old transport are never reconstructed or requeued. Existing reply-affinity validation drops old-epoch replies. Exact old release precedes fresh claim, and stale old callbacks cannot clear a new token.

### 8. Preserve distribution and dependency boundaries

All lifecycle code remains under `SDK`; Core and wire protocol are unchanged. Public signatures use Foundation and supported NearWire types only. SwiftPM and CocoaPods compile this same consumer form in Swift 5 language mode:

```swift
let policy = try NearWireReconnectionPolicy(
  maximumAttempts: 5,
  initialDelay: .seconds(1),
  maximumDelay: .seconds(8)
)
let configuration = try NearWireConfiguration(reconnectionPolicy: policy)
let nearWire = NearWire(configuration: configuration)
await nearWire.disconnect()
await nearWire.suspendConnection()
await nearWire.resumeConnection()
```

No product, target, pod subspec, dependency, entitlement, privacy declaration, persistence, observer, log, or analytic is added.

## Risks / Trade-offs

- **A pairing code remains in memory longer than one admission** -> Retain one actor-owned pending/active capsule, never place it in delay or route owners, clear it on every defined intent boundary, and document that it is a selector rather than a credential.
- **P2P recovery can increase energy use** -> Disable it by default, use an intent-wide budget that does not reset on brief success, cap delay, classify deterministic failures as permanent, and cancel on suspension or disconnect.
- **The host can forward incorrect multi-scene lifecycle policy** -> Provide policy-neutral explicit methods and document that scene aggregation belongs to the host.
- **Lease runtime failure can prevent later recovery** -> Preserve fail-closed exact-token semantics; report a safe ownership failure and stop bounded recovery rather than clearing or resetting ownership.
- **State and status subscribers may observe only the newest transition** -> This is intentional for UI/status observation; no history guarantee is made.
- **A Viewer may disappear while the App is suspended** -> Resume performs fresh discovery and can end disconnected with a safe error; it does not assume the prior endpoint remains valid.
- **A failed terminal wait cannot prove cleanup** -> Keep the lease vaulted and the shared cleanup result incomplete rather than falsely allowing disconnect completion or replacement.

## Migration Plan

1. Add the new policy and status types with default-disabled behavior so existing source continues to compile and behave as one explicit attempt.
2. Extend internal orchestration and deterministic seams, then add lifecycle tests before enabling production paths.
3. Update SwiftPM and CocoaPods consumer fixtures and documentation.
4. If rollback is required before release, remove the new APIs and lifecycle controller; the existing one-attempt connect path remains the behavioral baseline because the default policy introduces no automatic retries.

## Open Questions

None. UI binding, performance collection, and Viewer lifecycle are intentionally assigned to later roadmap changes.
