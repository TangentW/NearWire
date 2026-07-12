# SDK Active Event Pump

## Current Boundary

NearWire contains a repository-internal active Event pump for one admitted App session. It is intentionally not a supported SDK API or SPI. The public connection coordinator supplies the admitted attachment and process lease, runs this pump, retains its lifetime handle, and maps its closed internal failures to supported SDK state and errors.

Constructing the pump starts no task, timer, queue operation, transport send, Event publication, lifecycle observation, persistence, Keychain access, process lease, or UI work. One explicit `run()` binds the existing `NearWire` instance, negotiates the initial flow policy, and returns after activation. The returned lifetime handle owns cancellation. Its separate one-shot termination observer can outlive the handle without retaining it; releasing the final handle still cancels the session.

The pump does not replace the admitted session's secure channel, callback ingress, frame decoder, negotiated codec, route, cancellation relay, or terminal owner. Channel callbacks continue through the same bounded ingress and permanent session core from TLS admission through active transfer.

Before owner binding mutates active state, the runner creates one immutable live-operation value bound to that exact `NearWire` owner, secure channel, session clock, and operation gate. Wake registration/removal, schedule observation, queue drain, mailbox capacity/admission/completion, incoming publication, observer cancellation, and terminal close all pass through typed closures or named hooks. Expiration, route-drop, candidate, and Event-mailbox claims have operation-specific barriers, so tests do not depend on a global gate-call ordinal and cannot substitute route, clock, validation, mailbox, or gate behavior.

## Flow Policy

The Viewer requests both directional rates. The App computes each effective value independently:

```text
effective App uplink   = min(Viewer request, App maximum uplink)
effective App downlink = min(Viewer request, App maximum downlink)
```

The App sends an exact policy acceptance before the session becomes active. Zero pauses only business Events in that direction; Control traffic, TTL expiration, terminal input, and later policy offers remain live. Positive rates use a two-second bounded token bucket.

Later policy offers are ordered transactions. Event selection already in flight completes against its captured old-policy bucket. The acceptance is then encoded, both replacement bucket copies are prepared at one fresh bound-session-clock instant, the acceptance enters the secure mailbox, and both directions change together. A failure before mailbox admission preserves the old buckets.

## App-to-Viewer Transfer

The existing `NearWire` actor continues to own its offline queue. The pump installs one tokenized, level-triggered work callback and never moves an Event into a second rollback buffer. Each bounded turn:

1. refreshes the App-uplink bucket at the exact instance-local monotonic clock;
2. captures the available whole-token allowance;
3. expires due work and drops stale reply affinities without spending tokens or sequence values;
4. assigns the admitted route and next App-to-Viewer sequence only to the selected candidate;
5. encodes one V1 Event frame with its remaining origin-clock TTL; and
6. atomically admits the bytes and removes the queue entry through the shared terminal gate.

Wake assignment and its initial scheduling snapshot are one gate-linearized result. That initial snapshot is nonmutating: due work is reported as a level-triggered condition, then serviced by the ordinary bounded refresh path where every expiration claims the terminal gate separately.

The secure mailbox always reserves two maximum Control sends. Backpressure leaves the Event's ID, TTL, fairness position, and sequence unchanged. A constant-size blocked-candidate record and mailbox capacity predicate avoid repeated encoding while the known frame still cannot fit. Send completion, queue mutation, policy change, owner loss, terminal input, and the next TTL deadline can retry or invalidate a blocked candidate. Token availability is a wake only when transport is not blocked, so a full mailbox cannot create a polling loop.

Mailbox admission means only that bytes entered the local ordered TLS send queue. It does not prove peer receipt, decoding, display, storage, or application processing. NearWire V1 provides no Event acknowledgement, retransmission, replay, or exactly-once guarantee.

## Viewer-to-App Transfer

The continuous decoder accepts active single Events and negotiated batches, along with policy, ping/pong, drop-summary, error, and disconnect Control messages. Completed frames per callback are bounded. Input containing another complete frame beyond that quantum terminates with `activeWorkLimitExceeded`; a partial next frame remains in the decoder and counts only if a later callback completes it. The session does not create a continuation chain for hostile coalesced work.

Every incoming Event must match the admitted epoch, Viewer source, App target, and Viewer-to-App direction. Sequence begins at zero and rejects duplicates, gaps, the wrong direction, or exhaustion. Batch route, sequence, receiver-local TTL conversion, count, and byte admission are atomic. Retention charges each record's own deterministic encoded bytes; it does not divide a batch frame estimate across heterogeneous records. Transport cross-limits separately include the Event message wrapper and frame overhead.

Validated Events enter a bounded FIFO. An indexed minimum heap contains exactly one deadline node per retained FIFO item, so expiry does not accumulate stale heap tombstones. The combined FIFO and in-flight publication share the configured count and encoded-byte limits. Publication rechecks receiver-local TTL immediately before claiming the shared terminal gate and publishing to the existing bounded `NearWire.events` subscribers.

Slow subscribers retain the public stream's existing isolated overflow behavior. They do not block transport decoding or other subscribers.

## Bounds and Power Behavior

Validated defaults and hard maxima are:

| Limit | Default | Hard maximum |
| --- | ---: | ---: |
| Initial policy timeout | 10 seconds | 120 seconds |
| Retained incoming Events | 1,024 | 10,000 |
| Retained incoming encoded bytes | 8 MiB | 64 MiB |
| Completed frames per receive callback | 256 | 1,024 |
| Outbound queue service units per turn | 64 | 256 |
| Outbound queue-accounted bytes per turn | 2 MiB | 64 MiB |
| Incoming publications or expiries per turn | 32 | 256 |
| Deferred complete policy transactions | 32 | 128 |

Binding starts one wake-registration Task that awaits one bounded owner-actor operation. It carries the binding result token and captures the immutable live-operation value. Terminal cleanup invalidates that token and closes the gate but cannot directly cancel this unretained Task. A late result cannot commit; if registration already installed the matching wake, the stale-result path removes it. The Task then releases its captures when the actor call returns.

After binding, the core owns at most one policy deadline, negotiation-only owner refresh, outbound drain, outbound decision wake, incoming publication, and incoming decision wake. These retained Tasks have reference-identity tokens and are cancelled and released during terminal cleanup. The owner refresh is mutually exclusive with an active outbound drain, services one bounded queue quantum, and creates at most one successor when a signal was relatched or due maintenance remains. Token and TTL deadlines use one-shot sleeps. An idle active session has no recurring timer and performs no periodic queue scan.

A complete initial policy offer outranks another live owner-refresh successor after the current refresh proves that the owner is available. Any relatched Event hint remains set and resumes as bounded active work immediately after activation. Continuous App sends therefore cannot starve an already received Control offer until its negotiation deadline.

## Cancellation, Security, and Residual Scope

One lock-protected operation gate orders terminal cleanup against wake assignment, queue removal, transport admission, expiry, route drop, and incoming publication. An operation either commits completely before terminal close or makes no irreversible mutation. Cleanup closes that gate first, invalidates every task token, stops callback and work ingress, removes only the matching queue wake, clears session-owned incoming work, and cancels the secure channel at most once. It deliberately leaves the App's offline uplink queue intact.

All active bytes use the admitted mandatory TLS 1.3 channel. The pump adds no plaintext path, certificate bypass, persistence, authentication upgrade, or server dependency. Pairing code, Bonjour metadata, and connection-local certificate anchoring retain the security limits documented in [Transport-Security.md](Transport-Security.md) and [SDK-Session-Admission.md](SDK-Session-Admission.md).

The pump itself does not expose public lifecycle operations or claim process ownership. Public `connect(code:)` now composes it; public disconnect, reconnection, App lifecycle policy, background execution, and Event persistence remain later roadmap work.
