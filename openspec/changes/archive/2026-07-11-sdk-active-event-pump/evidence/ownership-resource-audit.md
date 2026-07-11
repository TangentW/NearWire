# Ownership and Resource Audit

## Cross-Actor Linearization

One `SDKActiveOperationGate` is created for the active session and closed synchronously at the start of terminal cleanup.

The following irreversible operations independently claim that gate:

- exact outbound wake-token assignment;
- each origin-queue expiry;
- each stale-route reply removal;
- each secure-mailbox admission plus queue removal, telemetry update, fairness commit, and returned sequence-prefix commit; and
- each Viewer-to-App Event publication.

Wake assignment and one nonmutating initial scheduling snapshot share the same gate claim. The snapshot reports exact candidate/deadline or due-work state but expires nothing. Due work is serviced afterward through the ordinary refresh path, where every expiration makes a separate gate claim and terminal may legally win between two expirations. All live owner/channel work is routed through one immutable operation value bound before active mutation to the exact owner, secure channel, clock, and gate. Named hooks cover expiration, route-drop, candidate, Event-mailbox admission/progress, mailbox completion, observer cancellation, and terminal close without relying on gate-call ordinals.

Core-local bucket and sequence copies are installed only by a live matching operation token after the corresponding owner-actor result returns. A terminal or stale result discards those copies without undoing owner or mailbox work that already won the gate. Terminal-first operations mutate nothing.

Dynamic policy offers defer while either an outbound drain or incoming publication is in flight. The old-policy operation completes first. Each queued offer then prepares both bucket copies at a fresh exact owner-clock instant, admits its acceptance, and installs both directions before later Event selection.

## Retention Bounds

| Resource | Bound and owner |
| --- | --- |
| Secure sends | `SecureTransportLimits` count/bytes; mailbox reserves two maximum Control sends for Event admission |
| Callback ingress | Admission count/receive-byte limits; one scheduled-drain latch |
| Partial frame | One decoder partial frame under lane limit |
| Completed decode work | Active completed-frame quantum; excess complete work fails closed |
| App uplink | Existing `NearWire` queue count/bytes; no pump-owned rollback copy |
| Blocked App candidate | One ID, encoded count, reservation, and progress generation; no encoded `Data` copy |
| Viewer downlink | Active count/encoded-byte limits shared by FIFO and in-flight publication |
| Downlink deadline index | Exactly one indexed heap node per FIFO item; no stale tombstones |
| Policy work | One active offer or at most configured deferred complete offers |
| Public streams | Existing independent bounded subscriber buffers |

Terminal cleanup clears decoder remainder, downlink FIFO and heap, in-flight publication charge, deferred policy offers, constant-size transport block, all task/token references, active dependency closures, and the exact wake registration. It deliberately preserves the App uplink queue and its stable Event identity/TTL.

## Task, Timer, and Power Audit

Construction starts no work. Active ownership retains at most:

- one binding-time wake-registration Task awaiting one bounded owner-actor operation;
- one policy deadline;
- one negotiation-only owner refresh, mutually exclusive with active outbound drain;
- one outbound drain;
- one outbound token-or-TTL decision sleep;
- one incoming publication;
- one incoming token-or-TTL decision sleep;
- one outbound signal-routing task plus one coalesced dirty successor.

The binding Task starts once, carries the binding result token, and captures the immutable live-operation value. The core deliberately retains no Task handle for this single actor call. Terminal cleanup invalidates its token and closes the operation gate, so a late result cannot commit; if registration already installed the matching wake, the stale-result path removes it. The Task may outlive cleanup until the bounded actor call returns, then releases its captures.

Every Task retained by the core carries an identity token, weakly routes back where appropriate, and is cancelled and released at terminal cleanup. There is no recurring timer. Empty queues schedule no decision wake. Zero-rate directions schedule only a known TTL deadline. Mailbox backpressure uses a constant-time capacity predicate before re-encoding a stable blocked candidate.

The owner refresh observes one bounded queue-service quantum. A signal relatched while its result is in flight, or remaining due maintenance reported by that result, authorizes at most one matching successor. A captured owner-unavailable result is consumed before any buffered initial policy can activate. After a live result, the oldest buffered initial offer outranks another successor while the work hint remains latched for active drain. `testOwnerShutdownSignalDuringRefreshSchedulesOneSuccessor`, `testCapturedOwnerUnavailablePrecedesInitialPolicyActivation`, `testCapturedLiveOwnerResultAllowsDeferredInitialPolicy`, and `testInitialPolicyOutranksRelatchedOwnerSignalStorm` cover these boundaries.

## Public and Product Boundary

- No supported `NearWire` API, product, target, dependency, pod subspec, entitlement, privacy declaration, persistence path, Keychain path, UI, lifecycle observer, reconnection behavior, or process-lease claim was added.
- Active implementation types remain internal and are rejected by the existing SDK implementation-type consumer fixture.
- Core and SDK add no third-party runtime dependency.
