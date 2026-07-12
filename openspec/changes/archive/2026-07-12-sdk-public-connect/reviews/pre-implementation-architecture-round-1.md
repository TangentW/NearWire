# Pre-Implementation Architecture and API Review — Round 1

## Scope Reviewed

I reviewed the complete `sdk-public-connect` proposal, design, task plan, and five capability deltas against roadmap items 11 through 13 and the current `NearWire`, process-lease, session-admission, active-pump, state-stream, wire-model, and distribution implementations. This is a report-only review; no planning or production artifact was modified.

The intended composition is appropriately narrow in broad shape:

```text
connect(code:)
  -> validate code and reserve exact instance token
  -> claim process lease
  -> load installation ID and construct App hello
  -> publish discovering
  -> run existing admission
       -> publish connecting after exact discovery selection
  -> attach and run existing active pump
  -> transfer handle + termination observer + lease to active owner
  -> publish connected and return
  -> weak terminal observation -> detach -> publish disconnected
```

It correctly reuses `PairingCode`, `ViewerDiscoveryCoordinator`, `ProcessConnectionLeaseRegistry`, `SDKSessionAdmission`, `SDKActiveEventPump`, and the existing latest-value state hub rather than rebuilding those state machines. Public disconnect, reconnection, background policy, route replacement, UI, effective-rate exposure, delivery acknowledgement, and performance collection remain deferred to later roadmap items.

## Findings

### 1. P1 / High (confidence: 10/10) — Cancellation releases the process lease before the existing active session has reached terminal ownership

**Evidence**

- The design gives `SDKPublicConnectedSession` synchronous cancellation that both cancels the active handle and releases the lease immediately (`openspec/changes/sdk-public-connect/design.md:92-97`). Shutdown likewise detaches the slot before cancellation/release (`design.md:161-168`; `specs/sdk-async-facade/spec.md:5,12-20`).
- The current active handle's `cancel()` does not synchronously terminate the session. `SDKSessionCancellationRelay.requestCancellation()` only latches once and launches an unstructured Task to call the core actor (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:9-32`). Core terminal cleanup then launches another Task for channel cancellation (`SDKSessionTransportCore.swift:1842-1931`).
- Consequently, immediate lease release permits another instance or independently loaded image to claim and begin Keychain/discovery/admission while the previous core is still live and has not yet closed its active-operation gate. That contradicts the lease's role as the one connecting-or-connected owner (`openspec/changes/sdk-public-connect/specs/sdk-process-connection-lease/spec.md:3-7`) and makes “exact lease reuse” timing in task 3.5 ambiguous (`tasks.md:19`).

**Impact**

Shutdown, deinitialization, or future cleanup can briefly create two real connection operations even though both hold valid, non-overlapping lease tokens. Exact-token release prevents stale clearing, but it does not prevent this cancellation-to-terminal ownership gap.

**Required remediation**

Separate synchronous public detachment from lease release. Cancellation-first should synchronously detach/token-stale the public slot and request internal cancellation, but a cleanup owner must retain the exact lease until the admission attempt has returned or the active termination observer proves the core terminal. Define that handoff in the design and capability specs, including cancellation-first, terminal-first, failed cancellation delivery, shutdown, and deinitialization. Add barriers proving a competing instance cannot claim between cancellation request and internal terminal completion, and can claim immediately after the exact terminal cleanup releases the lease.

### 2. P1 / High (confidence: 10/10) — The new admission phase suspension has no exact cancellation or shutdown winner contract

**Evidence**

- The plan adds an async phase observer after exact discovery selection and before channel construction/startup (`openspec/changes/sdk-public-connect/design.md:117-127`; `specs/sdk-session-admission/spec.md:5-11`). The specification only says observer suspension remains “covered” and provides no cancellation-at-observer scenario or required post-suspension validation.
- In the current admission implementation, discovery success cancels the deadline and clears the discovery operation, but state remains `discovering` until the transport core and channel are constructed (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:129-175`). Cancellation in `discovering` stores an override and changes state to `cancelled` (`SDKSessionAdmission.swift:71-84`).
- Inserting the planned `await` in that interval creates an actor-reentrancy point. Without a normative post-observer token/cancellation check, cancellation or public shutdown can win while the observer is suspended, after which the resumed admission can still construct a channel and overwrite state with `transferred`.
- Task 3.3 tests emission count/order, while task 3.5 generically mentions shutdown at suspension points; neither defines the two allowed state/side-effect outcomes (`openspec/changes/sdk-public-connect/tasks.md:17-19`).

**Impact**

A cancelled or shut-down public attempt can publish or start secure connection work after it lost ownership. The outer public token can suppress a stale state callback, but it cannot undo channel construction or transport startup inside admission.

**Required remediation**

Specify one exact phase-observer gate: discovery-selection-first may invoke the content-free observer, but admission must revalidate its own exact state/token and pre-latched task cancellation after the observer returns and before core/channel construction. Cancellation-first must construct no channel; observer-first may publish `connecting`, after which cancellation must terminate without startup or produce a defined `connecting -> disconnected` order. Add deterministic barriers for task cancellation, public shutdown, discovery deadline staleness, and observer completion in both winner orders. The phase observer should remain a generic admission closure that captures the public token outside admission rather than making admission own public-orchestrator state.

### 3. P1 / High (confidence: 10/10) — App-hello Event-size composition mixes two different byte domains and leaves supported configurations predictably unconnectable

**Evidence**

- The public plan advertises `NearWireConfiguration.buffer.maximumEventBytes` directly as the App hello's `maximumEventBytes` and treats incompatible composition as `connectionInternalFailure` after lease claim (`openspec/changes/sdk-public-connect/design.md:99-113`; `specs/sdk-public-connect/spec.md:26-45`).
- The public buffer value is the deterministic accounting size of the queued `EventDraft`; current public validation allows values through 16 MiB (`SDK/Sources/NearWire/NearWirePublicModels.swift:53-84`; `Core/Sources/NearWireFlowControl/EventQueueConfiguration.swift:41-85`).
- The negotiated wire value instead bounds the complete encoded `WireEventRecord`, including IDs, route, sequence, timestamps, TTL, causality, and endpoints (`Core/Sources/NearWireTransport/WireEventPayloads.swift:296-332`). The record is necessarily larger than its queued draft for the same content.
- Current default wire limits permit only a 256 KiB Event record, the default Event lane permits a 1 MiB payload, default secure single-send capacity follows that lane, and the default active outbound turn is 2 MiB (`Core/Sources/NearWireTransport/WirePrimitives.swift:245-320`; `Core/Sources/NearWireTransport/SecureTransportPrimitives.swift:63-113`; `SDK/Sources/NearWire/Session/SDKSessionAdmissionModels.swift:289-370`). A currently valid 1 MiB or 16 MiB buffer configuration therefore cannot simply be copied into a hello built with default limits. Even equal nominal limits do not prove a maximum queued draft can form a wire record.
- The task plan has metadata and prebuffered-event tests but no exact/one-over cross-product covering queue accounting, record bytes, frame wrapper, transport capacity, and active-turn capacity (`openspec/changes/sdk-public-connect/tasks.md:8-11,15-19`).

**Impact**

The supported configuration API can succeed at initialization and then deterministically fail `connect` with an “internal” error, or accept an Event into the offline queue that later terminally fails wire encoding. The Viewer also receives a size claim whose unit does not match the App queue limit from which it was derived.

**Required remediation**

Define one explicit public connection-limit plan with distinct names and byte domains for queued-draft accounting, negotiated Event-record bytes, encoded Event-frame bytes, secure-mailbox admission, and active-turn accounting. Either derive a provably coherent set of wire/frame/transport/active limits from the public configuration with overflow-safe worst-case wrapper calculations, or reject unsupported public configurations with the existing public `invalidConfiguration` error and a fixed field before lease claim or state publication. Do not map a deterministic caller configuration mismatch to `connectionInternalFailure`. Add exact-boundary and one-over tests, including a maximum accepted queued draft that really encodes and a maximum incoming negotiated record that really fits all downstream bounds.

### 4. P2 / Medium (confidence: 9/10) — The error contract claims post-return terminal mapping without any supported observation path

**Evidence**

- The proposal promises to map pairing, ownership, admission, activation, and terminal failures into public `NearWireError.Code` values (`openspec/changes/sdk-public-connect/proposal.md:7-11`). The design says mapping is exhaustive over the internal session enum (`design.md:129-151`).
- `connect(code:)` returns immediately after activation, and the only supported post-return signal remains payload-free `NearWireState.disconnected` (`design.md:34-54,153-159`; `specs/sdk-public-connect/spec.md:73-92,110-130`). No error stream, last-error property, terminal result, or connection handle exists in this change.
- `connectionClosed` is observable when admission receives a remote close before successful return, but an active `transportFailed`, `routeMismatch`, `sequenceViolation`, `clockFailed`, or other terminal code after return has nowhere to produce a public error. Mapping it and discarding the value is not a supported semantic.
- Roadmap item 12 asks for admission and ownership failures; final lifecycle semantics belong to item 13 (`Documentation/Implementation-Roadmap.md:51-57`).

**Impact**

Implementers and tests cannot agree whether active terminal reasons are intentionally hidden, should be stored, or require a new public API. Documentation may promise diagnostics that applications cannot receive.

**Required remediation**

Keep this change narrow: define public thrown-error mapping as failures that complete `connect(code:)` before successful return. Explicitly state that post-return active termination publishes only `disconnected` in item 12 and that terminal-reason observation is deferred to `sdk-connection-lifecycle`. Retain `connectionClosed` for a remote close during initial admission. Update the exhaustive-map task to distinguish connect-completion mapping from terminal-observer state classification. Adding a last-error or terminal-result API in this change is not recommended because it expands roadmap item 12.

### 5. P2 / Medium (confidence: 10/10) — The active owner retains the pairing code solely for a later feature that is out of scope

**Evidence**

- The design and normative spec transfer the normalized pairing code into `SDKPublicConnectedSession` and retain it until active termination (`openspec/changes/sdk-public-connect/design.md:92-97`; `specs/sdk-public-connect/spec.md:47-51,110-114`).
- This change exposes no pairing-code getter, code change, reconnect, or retry policy, and explicitly forbids retaining a code for retry after terminal state (`specs/sdk-public-connect/spec.md:5-7,133-140`). Retained-code reconnection is assigned to roadmap item 13 (`design.md:185-187`; `Documentation/Implementation-Roadmap.md:55-57`).
- Existing admission already drops its pairing-code value as soon as the discovery operation has been created (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:123-126`). The proposed public active owner would reintroduce a longer-lived copy that no current operation consumes.

**Impact**

Sensitive user-entered data remains in memory for the full session without providing item-12 behavior. It also quietly pre-shapes the later reconnect design before that change reviews whether retaining a code is appropriate.

**Required remediation**

Let the attempt own the normalized code only until it has been transferred into admission/discovery, then clear the public copy. Remove the code from `SDKPublicConnectedSession`, its cleanup contract, retention audit, and active-owner tests. If item 13 later needs retained-code reconnection, add that retention there with its own lifecycle, security, and UI decisions.

### 6. P2 / Medium (confidence: 9/10) — “Deinitialization during a connection attempt” is not a reliable public lifecycle or test scenario

**Evidence**

- The active-owner scenario says the final `NearWire` reference may be destroyed with either an attempt or an active session, and task 3.5 requests deinitialization tests at every suspension (`openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:121-125`; `tasks.md:19`).
- The only public operation is an async instance actor method (`design.md:15,34-42`; `specs/sdk-public-connect/spec.md:3-7`). The Task executing that instance method owns the actor for the duration of the call. Releasing the application's separate reference cannot make the actor's deinitializer run while `connect` remains suspended.
- Active-session deinitialization after `connect` returns is valid and important because the terminal observation Task is deliberately weak (`design.md:153-157`). Attempt cleanup, however, must be driven by connect-task cancellation or explicit `shutdown`, not by an optimizer-dependent assumption that `self` can disappear from a live instance-method frame.

**Impact**

The plan requires a public race test whose triggering condition cannot be guaranteed, and may lead implementation code to rely on deinitialization for attempt cleanup that only occurs after the attempt already completed.

**Required remediation**

Narrow the deinitialization guarantee and test to an active owner after successful return, plus defensive cleanup of internal owner objects. Specify task cancellation and `shutdown()` as the two attempt-time cancellation mechanisms. Add a test showing that dropping an external reference does not implicitly cancel a live connect Task, and retain explicit cancellation/shutdown tests at every real suspension point. Do not rely on actor deinitialization as an attempt-time control path.

## Testability and Compatibility Notes

- The existing SwiftPM/CocoaPods products, iOS 16 deployment target, Swift 5 language mode, public actor facade, closed error type, latest-value state hub, process lease, admission seams, and active-pump barriers provide the right base for deterministic implementation tests.
- After the findings above are remediated, the task plan should enumerate the connection path by irreversible boundary: instance-slot reservation, lease claim, identity read/add, phase-observer suspension, channel construction, admission result, pump attachment, activation commit, owner transfer, connected publication, terminal observation, and terminal lease release. Each suspension needs cancellation-first, operation-first, shutdown-first, and stale-token delivery where applicable.
- The planned production integration should enter through public `connect(code:)`, but deterministic discovery injection remains necessary; live Bonjour must not become the race oracle.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive` passes, and `git diff --check -- openspec/changes/sdk-public-connect` reports no whitespace error. Structural validity does not resolve the semantic gaps above.

## Unresolved Count

**6 unresolved findings: 3 High and 3 Medium. Architecture/API planning closure is not granted.**
