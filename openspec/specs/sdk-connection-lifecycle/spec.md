# sdk-connection-lifecycle Specification

## Purpose
TBD - created by archiving change sdk-connection-lifecycle. Update Purpose after archive.
## Requirements
### Requirement: Reconnection policy is exact, default-disabled, and intent-bounded

The SDK SHALL expose `NearWireReconnectionPolicy` as a public `Equatable, Sendable` struct with public static `disabled`; public read-only `isEnabled`, `maximumAttempts`, `initialDelay`, and `maximumDelay`; and a throwing public initializer taking `maximumAttempts: Int`, `initialDelay: Duration = .seconds(1)`, and `maximumDelay: Duration = .seconds(30)`. Disabled SHALL expose false, zero attempts, and zero delays. The initializer SHALL create only an enabled policy and accept attempts in `1...20`, initial delay from 100 milliseconds through 60 seconds, and maximum delay from initial delay through 300 seconds. Exact checked Duration-to-nanosecond validation SHALL fail with `invalidConfiguration` at fixed fields `reconnectionPolicy.maximumAttempts`, `reconnectionPolicy.initialDelay`, or `reconnectionPolicy.maximumDelay`.

`NearWireConfiguration` SHALL expose public read-only `reconnectionPolicy` and add a source-compatible trailing initializer parameter defaulted to `.disabled`. Enabled-policy attempt `n` SHALL wait `min(maximumDelay, initialDelay * 2^(n - 1))` with cap-before-multiply arithmetic. The attempt count SHALL be a total budget for one intent, reset only by successful initial connect or explicit resume, and SHALL NOT reset when an automatic attempt briefly reaches connected. Exhaustion SHALL clear intent and leave no delay or route work. Disabled policy SHALL perform no automatic attempt; explicit resume SHALL authorize exactly one immediate attempt and preserve intent after a transient failure.

#### Scenario: Existing App uses defaults

- **WHEN** an App uses the source-compatible default configuration and an active route fails
- **THEN** no automatic delay or replacement starts and the intent remains available only for explicit resume or disconnect

#### Scenario: Flapping Viewer repeatedly reaches connected

- **WHEN** each automatic replacement connects and immediately ends transiently
- **THEN** the intent-wide attempt number continues increasing, work stops at the configured total, and brief success never resets the budget

#### Scenario: Invalid policy is constructed

- **WHEN** an attempt count or exact Duration is outside its range or maximum is below initial
- **THEN** configuration fails at its fixed field before a NearWire instance or side effect exists

### Requirement: One actor intent capsule owns pairing lifecycle

After pairing validation and before the first suspension, the actor SHALL install one pending intent capsule containing the normalized pairing code, lifecycle generation, zero used automatic attempts, and pending phase. Admission MAY own one separate one-shot discovery transfer, but route owners and the raw method argument SHALL NOT be retained or reparsed to recreate intent. The pending capsule SHALL authorize no recovery. Connected commit SHALL atomically promote that same capsule to active intent without making another lifecycle copy.

Every initial failure, Task cancellation, explicit disconnect, suspension before first connected commit, shutdown, and stale completion SHALL clear pending intent. After promotion, explicit disconnect, permanent recovery failure, enabled-policy exhaustion, and shutdown SHALL clear active intent. Active connection, post-commit suspension, enabled recovery with budget, and disabled-policy transient disconnection MAY preserve it only in actor memory. Delay Tasks, attempt/active owners, terminal coordinators, Keychain, Events, public status, errors, reflection, diagnostics, and logs SHALL retain no code. String zeroization is not promised.

#### Scenario: Initial connection promotes intent

- **WHEN** connected commit succeeds
- **THEN** the one pending capsule becomes active in the same actor turn and no second lifecycle code owner survives

#### Scenario: Initial connection never commits

- **WHEN** any identity, discovery, admission, activation, cancellation, disconnect, suspension, or shutdown path wins first
- **THEN** pending intent is cleared and stale completion cannot recreate it

### Requirement: Explicit connect rejects existing lifecycle ownership

Explicit connect preflight SHALL use this exact order: shutdown, pre-latched caller Task cancellation, suspension, current initial/recovery attempt or unresolved cleanup receipt, active route, retained active intent, pairing validation, limit/version validation, reservation, and lease claim. Results SHALL be shutdown, connectionCancelled, `connectionSuspended`, connectionInProgress, alreadyConnected, `connectionIntentExists`, invalidPairingCode, invalidConfiguration, then mapped lease error. Explicit connect SHALL never supersede intent, recovery, or cleanup; changing code requires `await disconnect()` first.

#### Scenario: New code arrives during recovery delay

- **WHEN** explicit connect runs while a recovery delay, attempt, cleanup receipt, or retained intent exists
- **THEN** its fixed ownership error wins without validating or retaining the new code and without starting another route

#### Scenario: Connect is attempted while suspended and idle

- **WHEN** suspension is latched without intent
- **THEN** connect returns connectionSuspended before input validation or lease work

### Requirement: Disconnect uses one shared exact cleanup receipt

The SDK SHALL expose idempotent `public func disconnect() async`. It SHALL clear pending/active intent, suspension, resume request, retry progress, and last error; invalidate successor authority; cancel one current delay or attempt/active target; and prevent stale work from starting another route. It SHALL complete only after the exact current direct cleanup or sole terminal coordinator invokes exact release and settles that route's receipt. Release synchronization failure MAY make future claim unavailable but SHALL settle after the exact invocation. Terminal-wait failure SHALL vault the lease and leave the receipt and disconnect deliberately incomplete because cleanup cannot be proven.

The actor SHALL retain one constant-space cleanup receipt with one shared `Task<Void, Never>` rather than per-caller continuations. Any number of disconnect or suspension callers MAY await that Task; caller Task cancellation SHALL not end the lifecycle request or return the nonthrowing method before cleanup. Receipt settlement SHALL occur by exact route token before lifecycle-generation checks, so old callers finish while stale callbacks cannot mutate current intent, state, status, or a newer route. No successor claim SHALL begin while a receipt is unresolved.

Disconnect is a connection-work no-op only when intent, route/attempt, recovery Task, and receipt are absent; it MAY still clear suspension or an old status error. Concurrent calls SHALL issue one cancellation and one release path.

#### Scenario: Disconnect while connected

- **WHEN** callers await disconnect with an active route
- **THEN** they join one receipt and return after one terminal observation and exact release invocation

#### Scenario: Generation changes before old delivery

- **WHEN** old post-release delivery arrives after lifecycle invalidation
- **THEN** the old receipt settles once but no stale state, status, intent, recovery, or newer slot changes

#### Scenario: Terminal wait fails

- **WHEN** the sole terminal wait cannot produce terminal evidence
- **THEN** the lease remains fail-closed and disconnect does not falsely report completion

### Requirement: Suspension and resumption are explicit host policy

The SDK SHALL expose idempotent `public func suspendConnection() async` and nonblocking `public func resumeConnection()`. It SHALL register no UIKit, SwiftUI scene, NotificationCenter, reachability, or background-execution observer. Suspension SHALL latch even with no intent. It SHALL cancel delay/current route, await the shared receipt, and publish disconnected after cleanup when a route existed. Before initial connected commit it SHALL clear pending intent; after commit it SHALL preserve active intent.

Resume SHALL clear suspension. It SHALL reset the intent's recovery campaign and schedule attempt one only after suspended cleanup or from a disabled-policy transient-disconnected result. When resume follows suspension before that route's cleanup receipt settles, it SHALL store only one Boolean request and start after receipt settlement. Enabled policy SHALL use the configured delay for attempt one; disabled policy SHALL make the single explicit attempt immediately. Resume with no intent, while connected, during initial connect, or while any automatic/explicit delay or attempt is current SHALL be inert: it SHALL start no work, consume or reset no budget, and store no deferred request.

Shutdown SHALL override every command. A later disconnect SHALL monotonically clear a prior suspension/resume request and prevent successor work. Disconnect and suspension SHALL override caller Task cancellation of an initial connect, while every non-shutdown winner makes that connect return connectionCancelled.

#### Scenario: Host does not forward lifecycle policy

- **WHEN** an App never calls suspend or resume
- **THEN** NearWire observes no platform lifecycle and performs no automatic background transition

#### Scenario: Resume arrives before suspended cleanup completes

- **WHEN** resume clears the latch while the old receipt remains unresolved
- **THEN** one Boolean request waits and no claim occurs until exact receipt settlement

#### Scenario: Resume is repeated while connected or recovering

- **WHEN** resume runs with a healthy active route, an initial connect, or a current automatic or explicit recovery campaign
- **THEN** state, status, budget, route, and deferred-resume ownership remain unchanged

#### Scenario: Disabled explicit resume fails transiently

- **WHEN** its immediate attempt one fails transiently
- **THEN** state becomes disconnected, intent remains for another explicit host action, and no second attempt starts automatically

### Requirement: Recovery disposition is exhaustive and phase-aware

Every closed internal code plus origin phase SHALL map exhaustively to one content-safe `NearWireError` and transient, permanent, or lifecycle-cancellation disposition. Active-route transport failure, active-route or pre-active valid remote close, discovery timeout/unavailable/failure, and session timeouts SHALL be transient. Pre-active recovery `transportFailed` SHALL be permanent because it may represent deterministic TLS trust, identity, or ALPN failure. Clock failure SHALL be permanent. Local configuration/encoding/ownership or invariant failure, local-network denial, ambiguous discovery, incompatible/rejected Viewer, identity mismatch, protocol/sequence/route violation, hostile-work/ingress limit, and owner unavailability SHALL be permanent. Disconnect, suspension, caller cancellation, stale generation, and shutdown SHALL never recover.

The mapping SHALL discard pairing codes, advertised names, endpoints/interfaces, Viewer/App IDs, Bundle metadata, certificate/fingerprint data, raw Network/Security errors, remote text, wire bytes, Events, and application content. A new code without a disposition SHALL fail exhaustive compilation or validation. No retry SHALL weaken TLS or permit plaintext fallback.

#### Scenario: Established transport fails

- **WHEN** active-route transport failure occurs with enabled budget remaining
- **THEN** safe status records it and the next eligible attempt is scheduled

#### Scenario: Pre-active TLS path fails

- **WHEN** a recovery attempt reports transportFailed before active commit
- **THEN** it is permanent, intent clears, and no repeated TLS or plaintext attempt occurs

#### Scenario: Viewer closes a pre-active recovery route cleanly

- **WHEN** recovery receives the valid remoteClosed code before active commit
- **THEN** it consumes the current attempt and may schedule only the next remaining intent-budget attempt

### Requirement: Connection status follows the canonical lifecycle matrix

The SDK SHALL expose supported `NearWireConnectionStatus` with public read-only `state`, optional `lastError`, optional `reconnectAttempt`, and `isSuspended`; actor-isolated `connectionStatus`; and nonisolated `connectionStatuses`. Each subscription SHALL first receive current snapshot, retain only newest pending value, be removable by cancellation, and not mutate lifecycle. One actor turn SHALL update state and status current values coherently and suppress duplicates. Independent state/status streams MAY coalesce different intermediate values, but each status SHALL be internally coherent and current values SHALL agree after the turn.

Canonical outcomes SHALL be: idle suspend stays idle with suspended true; idle resume clears it with no work; resume while connected, initial-connect pending, or recovery current changes nothing; initial phases carry pending intent and no retry number; initial success is connected with active intent and no error; initial failure clears intent and exposes its error only by throw; disabled active transient is disconnected with safe error and retained intent; enabled transient with budget is reconnecting with the total attempt number; automatic success is connected with cleared public error and preserved used budget; permanent failure or exhaustion is disconnected with safe error and no intent; suspended active/recovery becomes disconnected after receipt with no error, no retry number, suspended true, and retained intent; disconnect becomes disconnected after receipt with no error, no retry number, suspended false, and no intent; shutdown is final with cleared error/progress/suspension/intent.

During cleanup, prior state remains until receipt settlement while suspension MAY already be visible. Recovery SHALL remain reconnecting through delay, discovery, admission, and activation. Repeated resume SHALL not reset a current campaign. Manual disconnect SHALL clear lastError even if state was already disconnected. Shutdown SHALL publish one final status and finish the stream.

#### Scenario: Late subscriber joins attempt two

- **WHEN** a status subscriber starts during recovery attempt two
- **THEN** its first value reports reconnecting, attempt two, current safe error, and current suspension value

#### Scenario: Slow state and status subscribers coalesce differently

- **WHEN** several actor transitions occur before both streams consume
- **THEN** each retains only its newest value without promising cross-stream event pairing and current actor values remain coherent

#### Scenario: Disconnect clears a disconnected error

- **WHEN** disconnect runs after a disabled transient or permanent terminal status
- **THEN** no connection work restarts and the resulting coherent status clears the error and intent according to the matrix

### Requirement: Recovery replaces routes without replay or overlap

After exact old release and receipt settlement, generation-current recovery SHALL use the actor intent only at immediate route construction. Delay Task SHALL capture only generation, attempt number, delay, and cancellation-completion state; it SHALL retain no code, actor, route, endpoint, or metadata. Production sleep SHALL be cancellation-cooperative. Invalidating commands SHALL cancel and wait or defer successor work until Task completion acknowledgement. A held injected sleeper SHALL delay cleanup rather than permit a second Task. Deinitialization SHALL explicitly cancel delay work.

Every replacement SHALL claim a fresh exact lease and create fresh discovery, TLS, hello/admission, session epoch, sequence state, pump, route, and coordinator. No old/new lease, channel, route, or epoch SHALL overlap. Only Events still in the bounded offline queue SHALL be eligible. Bytes accepted by the old transport SHALL NOT be reconstructed, requeued, or resent. Old-epoch replies SHALL be dropped by existing route-affinity validation. Stale old release SHALL NOT clear a newer token.

#### Scenario: Delay is cancelled while held

- **WHEN** disconnect or suspension invalidates a held recovery sleep
- **THEN** no successor Task is installed, no code is retained by the Task, and cleanup waits for its completion acknowledgement

#### Scenario: Old transport accepted an Event

- **WHEN** its remote outcome is unknown at terminal state
- **THEN** replacement does not put those accepted bytes back into the offline queue

### Requirement: Lifecycle work remains constant-space and dependency free

The actor SHALL retain at most one pending/active intent, one recovery Task, one current route slot, one terminal coordinator per live route, one cleanup receipt with one shared completion Task, and one Boolean resume request. It SHALL retain no per-caller waiter list and create no recurring timer or poll. At enabled exhaustion, all delay/route owners and intent SHALL clear. Disabled transient intent may remain only until explicit disconnect, resume, or shutdown. No third-party runtime dependency, persistent storage, log, analytics, product, target, pod subspec, entitlement, or privacy declaration SHALL be added. SwiftPM and CocoaPods SHALL expose equivalent lifecycle API in Swift 5 language mode for iOS 16 or later.

#### Scenario: Concurrent cleanup callers are stressed

- **WHEN** many callers await one held disconnect or suspension boundary and some caller Tasks are cancelled
- **THEN** the actor still owns one receipt and one cleanup path, and every call returns only after that shared Task completes

#### Scenario: Intent budget exhausts across flapping success

- **WHEN** the configured total is consumed across failures and brief successful routes
- **THEN** intent, Task, route, and recurring work are absent and status ends disconnected

