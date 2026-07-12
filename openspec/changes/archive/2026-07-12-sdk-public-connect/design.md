## Context

NearWire already has exact internal owners for pairing discovery, one process-wide lease, TLS admission, the permanent session core, and one bounded active Event pump. Public composition must preserve those owners under actor reentrancy, synchronous cancellation callbacks, non-cancellable Security IPC, one-shot terminal observation, and owner destruction. It must not create a strong cycle between the hidden active handle and the facade.

## Goals and Non-Goals

This change adds only `public func connect(code: String) async throws`, truthful public connection phases, safe pre-return errors, stable App hello identity, exact cleanup, and deterministic tests. It does not add public disconnect, reconnect, background or App lifecycle policy, pairing replacement, Event persistence, Viewer trust, delivery acknowledgement, terminal-error history, UI, performance collection, logging, analytics, or raw protocol configuration.

Successful connect means TLS 1.3 transport and initial flow-policy activation. It does not mean Viewer authentication, Event receipt, persistence, or acknowledgement.

## Public State and Preflight

The existing state enum remains source-compatible. This change drives:

```text
idle or disconnected -> discovering -> connecting -> connected -> disconnected
```

`reconnecting` is not emitted. Post-return terminal reasons publish only disconnected.

One actor turn applies this precedence without suspension:

1. Shutdown returns `NearWireError.shutdown`.
2. Pre-latched Task cancellation returns `connectionCancelled`.
3. Existing attempt or active owner returns `connectionInProgress` or `alreadyConnected`.
4. Pairing failure returns `invalidPairingCode` at field `code`.
5. Limit-plan or SDK-version failure returns existing `invalidConfiguration` at a fixed field.
6. One attempt token and prior stable state are stored.
7. The process lease is claimed. Failure removes the exact slot and preserves prior state.

Thus same-instance state wins over invalid input, invalid input wins over cross-instance contention, and every failure before discovering preserves idle or prior disconnected state.

For an already-pending call, task-only cancellation before active transfer returns `connectionCancelled`. Token-current shutdown before actor connected commit overrides task cancellation and every lower-layer result and returns `NearWireError.shutdown`. Connected commit, state publication, and successful method return occur in one actor turn; later shutdown does not retroactively change success.

## Constant-Space Least-Privilege Limit Plan

Queue accounting, Event-record bytes, frame payload and wrapper bytes, secure-mailbox bytes, active-turn accounted bytes, decoder work, and incoming retention are distinct domains.

The negotiated Event-record maximum is independent of `buffer.maximumEventBytes`. It equals the fixed `EventValidationLimits.maximumEncodedContentBytes` plus one checked exact maximum for every non-content V1 record byte: maximum Event type, endpoint identifiers, UUIDs, sequence, timestamps, TTL, causality, schema, keys, escaping, punctuation, and record syntax. `EventContentCodec` already validates the actual deterministic content bytes against that fixed content bound. A structural proof over every `JSONValue` case establishes that the record embeds the same deterministic content; the planner never infers content size from the queue's tagged Codable representation.

The planner performs bounded constant-time, constant-space checked arithmetic over schema constants and configuration integers. It never allocates or encodes a synthetic maximum payload. Each capacity is `max(reviewedDefault, exactRequiredValue)`, keeping a sufficient reviewed default and otherwise choosing the smallest required value:

- Event-lane payload fits the fixed maximum record.
- Secure single-send fits the exact frame.
- Pending-send bytes fit one maximum Event plus two maximum Control frames.
- Active-turn accounted bytes fit `buffer.maximumEventBytes`.
- Decoder and incoming queue fit the symmetric fixed negotiated record maximum.
- Every value remains within the existing hard maximum.

Failure returns `invalidConfiguration` at `buffer.maximumEventBytes` before token, lease, Keychain, discovery, or state work. The network maximum does not grow with the offline buffer setting, avoiding unnecessary downlink exposure.

Validation proves the record formula against production encoders using every JSON kind, control/slash escaping, Unicode, structural maxima, numeric extrema, maximum type and endpoint IDs, both causality optionals, timestamps, sequence, TTL, and schema. Generated/property cases assert actual record and frame sizes never exceed the formula. Exact/one-over tests traverse mailbox reservation, decoder, incoming queue, and active turn.

A peak-retention audit separately accounts for simultaneous queued draft, temporary envelope/record, encoded frame, secure mailbox, decoder work, incoming FIFO/in-flight item, and each public subscriber buffer. No individual limit is presented as a total-memory bound. Hostile tests cover a maximum Event, maximum batch, repeated frames through bounded overflow termination, and a maximum outbound candidate with no plaintext or reconnect fallback.

## Attempt State and Shared Authorization

NearWire owns one actor slot: none, attempt(token, operation), or active(token, connectedOwner). The attempt creates one `SDKSessionTransitionGate` before any suspension and uses it as the only chronology, target-generation, cancellation, authorization, terminal, transfer, and connected-commit authority for the entire attempt and any resulting lifetime:

```text
preparing -> identityWorker -> admission(generation)
          -> lifetimeRedirected -> activation(generation) -> finished
```

The gate stores a cancellation reason (`task` or `shutdown`), a monotonic target generation, and synchronous authorization. Cancellation-before-target rejects installation. Target-before-cancellation receives one request. Replacement removes only the exact previous generation. Every suspension rechecks both gate and actor token and explicitly cancels or transfers any returned owner that lost authority.

The exact same gate is passed into admission before run. A successful `SDKSessionLifetime` adopts it by identity rather than copying state into a new gate. The core therefore marks terminal on the same chronology that recorded any earlier Task cancellation, even when admission-result delivery is delayed. Internal admission callers that have no public attempt create one private default gate before their own run.

Task cancellation may win only through the gate's active-transfer claim; a successful transfer makes later task cancellation stale. Shutdown remains authoritative until connected-commit claim. Dropping an external NearWire reference does not cancel a live instance method because its Task retains the actor. Task cancellation keeps the public attempt slot until the current operation completes and cleanup releases; shutdown alone detaches the slot immediately.

## Immutable Orchestration Dependencies

Every NearWire binds one internal immutable `SDKPublicConnectionDependencies` at initialization. Production uses fixed operations; tests inject only internal alternatives. It supplies lease claim, off-actor identity load, Bundle metadata snapshot, admission and pump factories, and named non-mutating barriers immediately before and after:

- lease claim;
- identity completion;
- admission target installation and result;
- phase observer delivery and authorization;
- activation target installation and result;
- terminal-wait claim and registration;
- transfer claim;
- actor owner commit;
- terminal delivery;
- exact release.

Hooks carry no sensitive values and cannot replace token checks or validation. They permit both-winner evidence without sleeps, live Bonjour, real Keychain, or process-global corruption.

## Installation Identity

Identity access runs in one non-actor worker after lease claim. The worker retains fixed query data and attempt token but no NearWire, pairing code, Event, metadata, endpoint, certificate, or lease. Security IPC is synchronous and non-cancellable. Shutdown may detach public state, but the attempt keeps the lease until the worker returns; stale results cannot discover, publish, install, or release newer ownership.

Permanent version-independent literals are:

```text
service = com.nearwire.sdk.installation-identity
account = default
```

Changing them requires a separately specified coordinated migration across SwiftPM, CocoaPods, and independently loaded images.

The read dictionary contains exactly generic-password class, service, account, data-protection Keychain selection, return-data true, match-limit one, and `kSecUseAuthenticationUI: kSecUseAuthenticationUISkip`; it contains no synchronizable, access-group, or authentication-context key. The add dictionary contains exactly class, service, account, data-protection selection, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and 36-byte value data; it contains no synchronizable, access group, access control, label, comment, or caller override. Deprecated authentication-UI constants and warning suppression are forbidden.

A stored value must be exactly 36 UTF-8 bytes of canonical lowercase RFC 4122 V4 UUID text. Missing data performs one successful 16-byte `SecRandomCopyBytes`, sets V4 and RFC-variant bits, serializes once, and adds once. Duplicate add performs exactly one reread. A protected matching item skipped by the read appears missing, then add returns duplicate and the skipped reread remains missing; this fails closed. Every malformed, unexpected, inaccessible, random, add, or duplicate-reread failure is final. There is no update, delete, retry, sleep, poll, prompt, log, reflection, or OSStatus forwarding.

The item is device-local, non-migrating, and available only while unlocked. It is a Viewer correlation label, not a credential, and this change adds no reset API.

## App Hello and Pairing Lifetime

After identity load, one App hello uses V1, App role, a compiled version checked against root `VERSION`, canonical installation UUID, JSON, reviewed policies/capabilities, the fixed negotiated Event-record maximum, and optional Bundle metadata.

Only actual Bundle.main String values are accepted. Application identifier uses valid `CFBundleIdentifier`; version uses valid `CFBundleShortVersionString` then valid `CFBundleVersion`; display name uses valid `CFBundleDisplayName` then valid `CFBundleName`. Invalid or non-String values use only the documented valid fallback or are omitted. No property-list value is stringified or diagnosed.

The normalized pairing code is transferred into admission and the public attempt releases its reference immediately. Admission releases its own reference when discovery takes ownership. No connected owner, terminal coordinator, Keychain item, Event, public value, log, reflection, or diagnostic retains it. This promises reference release, not secure zeroization of Swift String storage.

## Phase Authorization

Admission receives the attempt's exact transition gate plus an optional content-free async observer returning `authorized` or `cancelled`. After exact discovery selection, admission checks its state, Task cancellation, and the gate; invokes the observer once; then requires authorized and immediately rechecks all three before core or channel construction.

Shutdown latching therefore happens-before the final synchronous check even if actor-target cancellation delivery is delayed. The outer observer publishes connecting only for the exact actor token and returns cancelled otherwise. Existing internal users receive an always-authorized gate and no observer.

## One Shared Session Lifetime and Transition Gate

Admission creates one `SDKSessionLifetime` containing the permanent cancellation relay, exactly one `SDKSessionTermination`, and the exact transition gate supplied before run. Admitted session, pump attachment, active handle, terminal coordinator, and actor commit share that identity; no layer creates a replacement termination value or transition authority. Existing internal callers can first wait through the active handle as before.

At the exact core terminal transition, before terminal waiter resumption, async channel cleanup, or callbacks, the core synchronously calls `markTerminal(code:)` on this gate. The gate stores the first terminal code and returns the previous public phase. `claimActiveTransfer()` and `claimConnectedCommit()` use the same lock. A successful connected claim is the linearization point for the actor's immediately following owner installation, connected publication, and method return in the same no-suspension turn. Terminal marking before either claim returns the exact terminal code; a successful claim before marking wins that row. There is no check-then-commit window and delayed scheduling of the async termination waiter cannot change the result.

Before active transfer, task cancellation and terminal marking use their order in this gate. Successful transfer makes later task cancellation stale. Shutdown is recorded independently and overrides task or terminal outcomes until a successful connected-commit claim; shutdown after that claim is later lifecycle state and cannot rewrite success.

Immediately after public admission returns, one atomic operation on that same gate moves the attempt's exact lease into one `SDKPublicTerminalCoordinator`. It clears attempt lease ownership only after coordinator acknowledgement. Cancellation already lives in the shared gate and requires no redirect or cross-lock copy. Either the attempt still owns and releases, or the coordinator owns and releases; never both or neither.

The coordinator starts exactly one termination wait before pump attachment. It is the sole owner of the wait, exact lease, and release-on-terminal action. Attempt and connected owners retain the coordinator but never call wait. Shutdown/deinitialization request cancellation through the shared gate and current admitted, attachment, or active owner and drop their edge; they neither transfer the termination object nor start a second Task.

The coordinator Task retains itself but no NearWire, pairing code, metadata, endpoint, certificate, Event, or internal error. Its async wait observes the code already synchronously marked by the core, invokes exact lease release once, and sends a weak tokenized callback. Failure to complete the wait intentionally keeps the lease fail-closed.

Normative outcomes are:

| Ordering | Connect result and state | Cancellation / wait / release |
| --- | --- | --- |
| Terminal mark before active-transfer claim | mapped pre-return failure; disconnected if discovery began | returned owner cancelled; one wait; one release after wait completes |
| Active-transfer claim before terminal mark | eligible for actor commit | later task cancellation follows gate state; same wait |
| Shutdown after transfer before actor commit | shutdown error; final shutdown; never connected | handle cancelled once; same wait; release after terminal |
| Terminal mark after transfer before connected-commit claim | mapped pre-return failure; disconnected | handle cancelled if needed; same wait; gated release |
| Connected-commit claim before terminal mark | connect succeeds and connected publishes/returns in that same turn | same wait later publishes disconnected and releases once |
| Shutdown/deinit with pending wait | shutdown final, or no state for deinit | handle cancelled once; coordinator continues; release at terminal |
| Stale terminal after newer token | no newer state/owner mutation | prior coordinator releases only its exact lease |

Hooks execute inside the actual terminal, transfer, and connected claim operations before mutation. Tests pause both winners at those critical sections, including delayed waiter scheduling and delayed weak callback delivery, and assert public result, state commits, cancellation count, exactly one wait, exact release count/timing, and later-claim eligibility.

## Lease Semantics

Before an admitted lifetime is returned, the attempt or its cleanup owner retains the exact lease through identity or admission operation completion. No terminal wait or coordinator exists on these branches.

For an ordinary token-current failure, including Task cancellation, the public slot remains attached until the operation completes. Cleanup invokes exact release once, then clears the exact slot, publishes disconnected only if discovering began, and completes connect with its mapped error or connectionCancelled. A second same-instance call continues to receive connectionInProgress until this sequence ends.

Shutdown is the sole pre-admission path that detaches the public slot immediately. The non-public attempt cleanup owner then completes the non-cancellable or cancelling operation, invokes exact release once, and performs no later actor slot or state mutation; final shutdown remains immediate, while the pending connect call returns shutdown only after cleanup has invoked release. Identity failure, stale identity after shutdown, discovery failure, phase rejection, and every admission failure without a lifetime follow exactly one of these two regimes.

After admission returns, the same-gate atomic handoff transfers the lease to the terminal coordinator. From acknowledgement onward only the coordinator releases after its sole wait observes the core's synchronous terminal mark. Cancellation or shutdown racing the handoff cannot make both owners release or leave neither owner. No cancellation-to-terminal lease gap exists.

The two exhaustive release regimes are: no-lifetime branches invoke idempotent exact release after their operation completes; lifetime branches invoke it only through the coordinator after the sole wait observes the core terminal mark. Successful Objective-C synchronization clears ownership. Failed claim exit, release enter, or release exit remains fail-closed and may make ownership unavailable for process lifetime. Disconnected, shutdown, retry, and deinitialization do not promise repair or reacquisition. Stale release never clears a newer token.

## Weak Active Owner Binding

The permanent core retains no strong NearWire reference after binding. It captures App maximum rates by value and removes strong `activeOwner` storage. `SDKActiveLiveOperations` captures NearWire weakly for clock, wake, schedule, drain, and publication and returns a closed owner-unavailable result when absent.

Owner disappearance closes through the existing active-operation gate and terminates with `ownerUnavailable`. If the actor is gone, its wake registration was destroyed; if it remains, exact token removal is still required. Channel, decoder, route, and terminal authority remain unchanged. A retain-graph audit must prove no path from core, live operations, callback ingress, channel, coordinator, or terminal Task strongly reaches NearWire.

## State, Errors, and Security Disclosure

Discovering publishes immediately before admission run. Connecting publishes only through authorized phase delivery. Active handle transfer then actor token check, owner installation, connected publication, and success return occur in order. Failures after discovering publish disconnected once. Shutdown is final and stale callbacks are inert.

Public additions are invalidPairingCode, connectionInProgress, alreadyConnected, anotherConnectionIsActive, connectionOwnershipUnavailable, connectionCancelled, discoveryTimedOut, localNetworkDenied, discoveryUnavailable, discoveryAmbiguous, connectionTimedOut, secureConnectionFailed, incompatibleViewer, viewerIdentityMismatch, viewerRejected, connectionClosed, and connectionInternalFailure. Existing invalidConfiguration handles deterministic pre-lease validation. Mapping is exhaustive for results observable before success. Post-return terminal errors create no undeliverable public value.

Messages and fields are fixed and exclude underlying descriptions, pairing/Bonjour data, endpoints, interfaces, certificates, identities, metadata, Events, protocol values, Security queries, OSStatus, identities, and addresses.

Documentation must enumerate automatic hello fields and say the pairing code is not a password; V1 encrypts but does not authenticate a pretrusted Viewer; an active local impersonator remains in scope; viewerIdentityMismatch is Bonjour-to-hello consistency only; the device-only installation ID permits cross-session correlation and has no reset here; the fixed symmetric peer Event bound has bounded CPU/memory exposure; and connect proves transport/policy activation only.

## Required Evidence

- Table-driven overlapping preflight and pending shutdown-result tests.
- Constant-space limit-formula proof, generated/adversarial encoder properties, exact/one-over boundaries, hostile incoming Event/batch/overflow tests, and peak-retention audit.
- Exact modern Keychain transcript dictionaries and call counts, including protected-item skip/duplicate/skip.
- Both-winner barriers at lock-linearized cancellation/target replacement, core-terminal versus active-transfer, and core-terminal versus connected-commit boundaries; deterministic async barriers at admitted-result, activation-result, release/delivery, phase-authorization, and shutdown boundaries; and exact-token source/integration audits for stale callbacks and the single coordinator wait.
- Retain-graph tests proving a live connect Task retains NearWire, but after successful return dropping the last App reference deinitializes NearWire, cancels the hidden handle, reaches terminal, and releases the lease through the coordinator.
- Pre-admission branch release tests, lease runtime failure tests, and production TLS supported-connect integration.
- SwiftPM/CocoaPods Swift 5 iOS 16 consumer parity, Security linking, public API inventory, and no new entitlement/privacy declaration.

## Residual Scope

Public disconnect, retained-code reconnect, transient-failure policy, foreground/background transitions, route replacement, terminal-reason observation, and final lifecycle semantics remain `sdk-connection-lifecycle` scope.
