# sdk-public-connect Specification

## Purpose
TBD - created by archiving change sdk-public-connect. Update Purpose after archive.
## Requirements
### Requirement: Public connect is one explicit instance operation

The SDK SHALL expose `public func connect(code: String) async throws` on the `NearWire` actor. Construction and every existing Event, buffer, stream, state, disconnect, suspend, and resume operation without active intent SHALL NOT start connection work. One successful explicit call SHALL validate, install one actor-owned pending intent capsule, reserve one exact instance attempt and cleanup receipt, claim the process lease, construct one App hello, explicitly run one admission and active pump, install one connected owner, promote the same intent, publish connected, and return in the same actor turn. Success SHALL mean only TLS transport and initial flow-policy activation.

Preflight precedence SHALL be shutdown, pre-latched Task cancellation, suspension, same-instance initial/recovery attempt or unresolved cleanup, active route, retained active intent, pairing validation, limit and SDK-version validation, exact intent/slot/receipt reservation, then lease claim. Results SHALL be shutdown, connectionCancelled, connectionSuspended, connectionInProgress, alreadyConnected, connectionIntentExists, invalidPairingCode, invalidConfiguration, or mapped lease error respectively. Failures before discovering SHALL preserve idle or prior disconnected state and clear pending intent after cleanup. Ownership state SHALL win before validation of a new code; valid input SHALL win over cross-instance contention. This operation SHALL expose no pairing getter, effective rate, Viewer identity, endpoint, certificate, lease, or pump API.

For a pending call, token-current shutdown before actor connected commit SHALL override Task cancellation and lower-layer results and return the existing shutdown error. Token-current explicit disconnect or suspension before actor connected commit SHALL return connectionCancelled. Connected commit, intent installation, and success return SHALL be indivisible with respect to later actor work.

#### Scenario: Explicit connection succeeds

- **WHEN** the exact Viewer admits and activates one valid request
- **THEN** connect returns after connected owner, pending-to-active intent promotion, and state commit
- **AND** eligible Events may transfer through the existing pump

#### Scenario: Overlapping preflight conditions exist

- **WHEN** multiple rejection conditions are true
- **THEN** the fixed order selects one result and starts no lower-precedence work

#### Scenario: Shutdown wins a pending attempt

- **WHEN** shutdown latches before actor connected commit
- **THEN** the pending call returns shutdown, final state is shutdown, and connected is never published

#### Scenario: Disconnect wins a pending attempt

- **WHEN** explicit disconnect or suspension latches before actor connected commit
- **THEN** the pending call returns connectionCancelled and lifecycle recovery does not start

### Requirement: Connection limits are constant-space and least-privilege

Before token or lease, the SDK SHALL derive immutable limits using bounded constant-time, constant-space checked arithmetic only. The symmetric negotiated Event-record maximum SHALL equal fixed validated deterministic-content bytes plus an exact maximum for all non-content V1 record syntax and fields; it SHALL NOT derive from queue-accounting bytes. A structural proof over every JSONValue case SHALL establish that production EventContentCodec validation governs the exact content embedded by the production wire encoder.

Frame payload, secure single-send, pending-send bytes including two maximum Control frames, active-turn accounted bytes, decoder work, and incoming retention SHALL each be `max(reviewedDefault, exactRequiredValue)` and SHALL remain within existing hard maxima. Active turn SHALL fit configured maximum queue accounting. No capacity SHALL be widened to a hard maximum by convenience, and connect SHALL allocate or encode no synthetic maximum payload. The network maximum SHALL remain fixed when `buffer.maximumEventBytes` changes.

Any failed proof SHALL return invalidConfiguration at `buffer.maximumEventBytes` before slot, lease, Keychain, discovery, or state work.

#### Scenario: Every valid content shape is encoded

- **WHEN** adversarial and generated Events span all JSON kinds, escaping, Unicode, structural and numeric boundaries, identifiers, causality, timestamps, sequence, TTL, and schema
- **THEN** actual record and frame bytes never exceed the fixed formula

#### Scenario: A required capacity crosses a hard bound

- **WHEN** checked arithmetic produces one byte beyond an existing hard maximum
- **THEN** connect returns invalidConfiguration with no connection side effect

#### Scenario: Buffer maximum changes

- **WHEN** App queue accounting is raised within supported limits
- **THEN** only the required active-turn accounting may rise and the symmetric peer Event maximum remains fixed

### Requirement: App hello metadata is bounded

After lease claim and identity load, the SDK SHALL construct one App hello from V1, App role, root-VERSION-checked compiled product version, canonical installation UUID, JSON, reviewed policies and capabilities, fixed negotiated Event-record maximum, and optional validated Bundle.main Strings. Application identifier SHALL use valid CFBundleIdentifier. Version SHALL use valid CFBundleShortVersionString then CFBundleVersion. Display name SHALL use valid CFBundleDisplayName then CFBundleName. Invalid or non-String values SHALL use only a valid documented fallback or be omitted; no property-list value SHALL be stringified or diagnosed. No raw protocol or transport configuration SHALL be public.

#### Scenario: Optional metadata is invalid

- **WHEN** a primary and fallback value are non-String or invalid
- **THEN** the field is omitted without content entering errors

### Requirement: Installation identity is exact, modern, bounded, and off-actor

Only after lease claim, one non-actor worker SHALL use permanent service `com.nearwire.sdk.installation-identity` and account `default`. The read dictionary SHALL contain exactly generic-password class, service, account, data-protection selection, return-data true, match-limit one, and `kSecUseAuthenticationUI: kSecUseAuthenticationUISkip`, with no synchronizable, access-group, or authentication-context key. The add dictionary SHALL contain exactly class, service, account, data-protection selection, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and 36-byte value data, with no synchronizable, access-group, access-control, label, comment, or override. Deprecated UI constants and warning suppression SHALL be forbidden.

A stored value SHALL be exactly 36 UTF-8 bytes of canonical lowercase RFC 4122 V4 UUID text. Missing SHALL perform exactly one successful 16-byte SecRandomCopyBytes, set V4/RFC bits, serialize once, and add once. Duplicate add SHALL perform one reread. Protected-item skip followed by duplicate and a second skip SHALL fail closed. Every malformed, unexpected, inaccessible, random, add, or reread failure SHALL be final with no update, delete, retry, sleep, poll, prompt, log, reflection, or status forwarding.

The worker SHALL retain no NearWire, pairing code, Event, metadata, endpoint, certificate, or lease. Cancellation MAY detach public state while synchronous IPC finishes; the attempt SHALL keep the lease and stale result SHALL start no work or affect newer ownership.

#### Scenario: Valid item exists

- **WHEN** the exact read returns one valid value
- **THEN** it returns with no random, add, update, or delete

#### Scenario: Protected item is skipped

- **WHEN** read appears missing, add reports duplicate, and the bounded reread is also skipped
- **THEN** identity fails closed without prompt, retry, update, or delete

### Requirement: Pairing-code retention is minimal

After pairing validation the actor SHALL retain one pending lifecycle capsule through initial admission. The public route attempt SHALL release its separate one-shot discovery transfer immediately after giving it to admission, and admission SHALL release that transfer when discovery takes ownership. Connected commit SHALL promote the same pending capsule without another lifecycle copy. The raw method argument SHALL NOT be retained or reparsed, and no current route owner, delay Task, terminal coordinator, Keychain item, Event, public value, error, log, reflection, or diagnostic SHALL retain the code. Every failed initial path, Task cancellation, pre-commit disconnect/suspension, permanent recovery failure, enabled exhaustion, and shutdown SHALL clear its applicable capsule. The SDK SHALL promise reference release, not secure String zeroization.

#### Scenario: Session reaches admission

- **WHEN** admission owns discovery input before connected commit
- **THEN** admission owns only its one-shot transfer while the actor pending capsule remains the sole lifecycle owner

#### Scenario: Connected lifecycle intent ends

- **WHEN** a terminal intent-clearing boundary wins
- **THEN** the actor clears the only retained lifecycle code and stale callbacks cannot recreate it

### Requirement: Attempt and session cancellation have one shared authority at each stage

The attempt SHALL create one `SDKSessionTransitionGate` before suspension and use it as the single chronology, cancellation reason, monotonic target generation, and synchronous authorization source for the attempt and any later session. Cancellation-before-target SHALL reject installation; target-before-cancellation SHALL receive one request; replacement SHALL remove only the exact generation; stale completion SHALL NOT affect a successor. Every suspension SHALL recheck gate and actor token and dispose any returned owner that lost authority.

The exact gate SHALL be passed into admission before run, and a successful lifetime SHALL adopt it by reference identity. Core terminal therefore shares chronology with Task cancellation even before admission-result delivery. Lease handoff SHALL occur atomically on this same gate and acknowledge coordinator ownership before the attempt clears its handle. Task cancellation SHALL be stale after successful active-transfer claim and SHALL keep the public attempt slot until operation completion and release. Shutdown SHALL remain authoritative until successful connected-commit claim and SHALL be the only pre-admission reason that immediately detaches the public slot. A live connect Task SHALL retain NearWire, so attempt cleanup SHALL not rely on actor deinitialization.

#### Scenario: Target replacement races cancellation

- **WHEN** admission completes while cancellation and activation-target installation race
- **THEN** exactly one generation owns cancellation and every stale owner is disposed

### Requirement: Connecting phase requires synchronous authorization

After exact discovery selection, admission SHALL check its state, Task cancellation, and the shared synchronous authorization gate; invoke at most one content-free observer returning authorized or cancelled; then require authorized and recheck all three before constructing core or channel. Shutdown latching SHALL be visible to the final gate check even when asynchronous admission cancel delivery is delayed. The observer SHALL publish connecting only for the exact actor token and return cancelled otherwise. Existing internal callers MAY use an always-authorized gate and no observer.

#### Scenario: Shutdown wins during observer suspension

- **WHEN** shutdown latches, the stale observer returns, and actor cancellation delivery is held
- **THEN** the synchronous final check prevents core, channel, transport, and attachment creation

### Requirement: One session transition gate and terminal coordinator own post-admission lifetime

Admission SHALL create one shared session lifetime containing the permanent cancellation relay, exactly one one-shot termination value, and the exact transition gate supplied before run. Admitted session, attachment, active handle, coordinator, and actor connected commit SHALL share it and create no replacement. Immediately after admission returns, one same-gate atomic handoff SHALL transfer the exact lease into one terminal coordinator and acknowledge ownership before the attempt clears its handle. The coordinator SHALL start exactly one wait before attachment and solely own the wait, lease, and release-on-terminal action. Attempt and connected owners SHALL never call wait.

At the exact permanent-core terminal transition, before waiter resumption or async cleanup, the core SHALL synchronously mark the first terminal code in the shared gate. Active-transfer and actor-connected-commit claims SHALL use that same lock. A terminal mark before a claim SHALL return the terminal code; a successful claim before marking SHALL win that ordering. The actor SHALL perform connected-commit claim, owner installation, connected publication, and successful return in one no-suspension turn. Hooks SHALL execute inside each claim before mutation so no check-then-commit gap exists and delayed waiter scheduling cannot change the winner.

Shutdown or deinitialization SHALL request cancellation through the current admitted, attachment, or active owner and drop its edge; the same coordinator and Task SHALL continue. The Task SHALL retain no NearWire, pairing code, metadata, endpoint, certificate, Event, or internal error. Terminal SHALL store its code, release the exact lease once, and send only a weak tokenized state callback. Failure to observe terminal SHALL keep the lease fail-closed.

Terminal-mark-before-transfer SHALL fail connect and publish disconnected if discovery began. Transfer-claim-before-terminal MAY proceed. Shutdown after transfer but before connected claim SHALL return shutdown without connected. Terminal mark after transfer but before connected claim SHALL fail connect. Connected claim before terminal mark SHALL return success, and later terminal SHALL publish disconnected. Task cancellation versus terminal before transfer SHALL use their order in the shared gate; shutdown SHALL override either until connected claim. Every ordering SHALL use one cancellation request per owner, one wait, and one exact release gate.

#### Scenario: Shutdown follows wait registration

- **WHEN** shutdown detaches an active or activating owner
- **THEN** it starts no second wait and the existing coordinator retains lease until terminal

#### Scenario: Duplicate wait is attempted

- **WHEN** validation tries to register another terminal wait
- **THEN** it is rejected and never treated as terminal evidence or a release trigger

### Requirement: Active binding does not retain NearWire

The permanent core SHALL capture App maximum rates by value and retain no strong NearWire reference. Every active owner operation SHALL capture NearWire weakly and return a closed owner-unavailable result when absent. Owner disappearance SHALL close through the active-operation gate and terminate with ownerUnavailable. Existing exact wake removal SHALL occur when owner exists; destroyed owner storage SHALL already have released registration. Channel, decoder, route, and terminal authority SHALL remain unchanged.

#### Scenario: Final App reference is dropped after connect

- **WHEN** no external reference remains after successful return
- **THEN** NearWire deinitializes, hidden active handle cancellation occurs, core becomes terminal, and coordinator invokes exact lease release
- **AND** no core, live operation, channel, callback, coordinator, or terminal Task strongly retains NearWire

### Requirement: Public states and errors are exact and content-safe

Discovering SHALL publish before admission; connecting only after authorization; connected only after actor owner commit. Failure after discovering SHALL publish disconnected once unless shutdown is final. Stale callbacks SHALL be inert and reconnecting SHALL not appear.

The SDK SHALL add invalidPairingCode, connectionInProgress, alreadyConnected, anotherConnectionIsActive, connectionOwnershipUnavailable, connectionCancelled, discoveryTimedOut, localNetworkDenied, discoveryUnavailable, discoveryAmbiguous, connectionTimedOut, secureConnectionFailed, incompatibleViewer, viewerIdentityMismatch, viewerRejected, connectionClosed, and connectionInternalFailure. Existing invalidConfiguration handles deterministic pre-lease failure. Mapping SHALL be exhaustive for results observable before success. Post-return terminal reasons SHALL create no error API.

Only fixed codes, fields, and messages SHALL be public. Underlying descriptions, pairing/Bonjour data, endpoints, interfaces, certificates, identities, metadata, Events, protocol values, Security queries, OSStatus, object identities, and addresses SHALL be excluded.

#### Scenario: Active terminal follows success

- **WHEN** any active terminal reason arrives after success
- **THEN** disconnected publishes without error history or reconnect

### Requirement: Lease cleanup is terminal and fail-closed

Before admission returns, the attempt or its cleanup owner SHALL retain the lease through identity or admission operation completion. These branches SHALL create no coordinator or terminal wait.

For a token-current ordinary failure or Task cancellation, the public slot SHALL remain attached until operation completion; cleanup SHALL invoke exact release once, then clear the exact slot, publish disconnected only if discovering began, and complete connect. For shutdown, the actor SHALL detach immediately and remain final; the non-public cleanup owner SHALL complete the operation, invoke exact release once, perform no later actor mutation, and only then allow the pending connect call to return shutdown.

After successful admission, the atomic handoff SHALL make the terminal coordinator the sole lease owner through attachment, activation, connected ownership, shutdown, deinitialization, and terminal. Cancellation or shutdown racing handoff SHALL leave exactly one owner. Public detachment SHALL NOT create a cancellation-to-terminal gap.

The exhaustive release regimes SHALL be: no-lifetime branches release after operation completion, while lifetime branches release only through the coordinator after its sole wait observes the synchronous terminal mark. Successful runtime synchronization SHALL clear ownership. Failed claim exit, release enter, or release exit MAY make ownership unavailable for process lifetime. No state, retry, shutdown, or deinitialization SHALL promise repair or reacquisition, and stale release SHALL never clear a newer token.

#### Scenario: Public state detaches before terminal

- **WHEN** cancellation or shutdown removes the slot while core can operate
- **THEN** the coordinator keeps the lease and competing claim still fails

#### Scenario: Identity fails before admission

- **WHEN** the bounded identity operation returns failure with no session lifetime
- **THEN** the attempt invokes exact release once before clearing its slot or completing connect
- **AND** it creates no terminal coordinator or wait

### Requirement: Public connect has no lifecycle policy

Each invocation of `connect(code:)` SHALL perform one initial attempt only and SHALL NOT retry that pending call. A successful call SHALL promote the actor intent governed by `sdk-connection-lifecycle`; later automatic recovery SHALL occur only after success, only under explicit bounded configuration, and only within the intent-wide budget. The connect operation SHALL NOT supersede existing intent, observe foreground/background state, request background execution, poll connectivity, reuse a route, or turn a thrown initial failure into hidden recovery.

#### Scenario: Initial attempt fails transiently

- **WHEN** a transport-like failure occurs before the explicit connect call succeeds
- **THEN** cleanup proceeds, the call throws its safe error, and no recovery or retained intent begins

