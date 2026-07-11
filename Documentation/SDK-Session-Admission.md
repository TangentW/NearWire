# SDK Session Admission

## Current Boundary

NearWire now contains the repository-internal App-side operation that turns one pairing code and one local App hello into one admitted secure session. It is not a supported SDK API. Normal Swift Package Manager and CocoaPods consumers cannot name the admission actor, its errors, its transport owner, or its handoff handles.

Constructing an admission value performs no discovery, permission request, network operation, task, timer, persistence, Keychain access, process-lease claim, SDK state mutation, or event transfer. Only one explicit internal `run()` starts work, and that operation is single-use.

Public connection APIs, process-lease orchestration, reconnection, background behavior, and lifecycle state publication remain later roadmap work. The repository-internal active transfer stage that consumes an admitted attachment is documented in [SDK-Active-Event-Pump.md](SDK-Active-Event-Pump.md).

## Sequence

Before discovery starts, admission requires a local hello with the App role and encodes it again with the exact configured wire limits. It also encodes the largest V1 pong. The cached hello, the pong, the secure transport send slots, and the count and byte budgets must all fit together. Invalid local configuration fails before any dependency starts.

A valid attempt follows one sequence:

1. Browse for the exact pairing-code-derived `_nearwire._tcp.local.` instance.
2. Accept one interface-neutral result and retain its advertised `vid` only for the next consistency check.
3. Construct the permanent session transport core, then construct one `SecureAppTransport` channel from the matched endpoint.
4. Wait for mandatory TLS 1.3 and `nearwire/1` ALPN readiness.
5. Send the cached App hello exactly once.
6. Decode exactly one Viewer hello through the continuous frame decoder.
7. Require the Viewer role and require its installation ID to derive the same `vid` that discovery reported.
8. Negotiate the registered V1 JSON codec, capabilities, send policies, and maximum event bytes.
9. While awaiting approval, accept only an exact acknowledgement, a valid rejection, bounded ping or pong traffic, a safe error, or disconnect.
10. Commit admission only after the entire receive chunk containing the acknowledgement has been processed successfully.

An acknowledgement must exactly match the negotiated version, codec, event limit, capabilities, policies, and Viewer installation ID. Its peer-supplied session epoch must be a valid canonical UUID. A valid policy message later in the acknowledgement chunk is retained for the event pump. A terminal, malformed, duplicate, or out-of-order suffix makes the provisional acknowledgement fail without returning a handle.

## Identity and Security Limits

All session bytes use the mandatory secure transport described in [Transport-Security.md](Transport-Security.md). There is no plaintext, arbitrary endpoint, custom service type, TLS-disable, certificate-bypass, or caller-supplied connection option in admission.

The `vid` comparison detects disagreement between the selected Bonjour registration and the decoded Viewer hello on this connection. It is not authentication. The pairing code is public discovery metadata, `vid` is a truncated public discriminator, and V1 TLS uses connection-local anchoring of the presented self-signed certificate. None of those values proves publisher uniqueness, binds the certificate to the installation ID, or provides continuity across connections.

V1 also has no handshake nonce, persisted epoch history, or replay store. A syntactically valid acknowledgement epoch is accepted without a freshness claim.

## Bounds and Deadlines

Admission uses fixed validated defaults and hard maxima:

| Limit | Default | Hard maximum |
| --- | ---: | ---: |
| Discovery timeout | 30 seconds | 120 seconds |
| Secure admission timeout | 15 seconds | 120 seconds |
| Pump attachment timeout | 5 seconds | 30 seconds |
| Retained ingress callbacks | 64 | 256 |
| Retained ingress receive bytes | 256 KiB | 1 MiB |
| Pre-acknowledgement work items | 32 | 128 |
| Pre-acknowledgement work bytes | 256 KiB | 1 MiB |
| Pre-active handoff work items | 64 | 256 |
| Pre-active handoff work bytes | 512 KiB | 1 MiB |
| Retained policy messages | 32 | 128 |
| Retained policy bytes | 256 KiB | 1 MiB |

Incoming complete frames and generated pong responses both consume cumulative work budgets. Retained policy messages have separate count and byte limits. Event-lane framing is rejected before payload reservation while the session remains pre-active.

Only one stage deadline exists at a time. A discovery match replaces the discovery deadline with the secure-admission deadline. A committed acknowledgement replaces that deadline with the pump-attachment deadline. Successful attachment cancels the attachment deadline.

## Ownership and Cancellation

The channel callback always targets one bounded lock-protected ingress. Pending and currently draining callbacks share the same count and byte accounting. The ingress processes at most eight items per actor turn before weakly scheduling the next turn, so a continuous producer cannot monopolize the core ahead of cancellation, deadlines, attachment, or pull work. The callback is never retargeted to the admission operation, the admitted handle, or the future event pump. The same core owns the channel, continuous decoder, negotiated codec, route, and policy handoff until cancellation or terminal failure.

The admitted handle and its one pump-attachment handle share one cancellation relay. The relay retains the core; the core does not retain the relay. Dropping the admitted handle after attachment leaves the pump handle in control. Dropping the final external handle or explicitly cancelling either handle requests core cancellation exactly once.

The policy handoff preserves one FIFO across attachment and permits one asynchronous pull at a time. Per-pull cancellation removes only that pull and does not terminate the session. Pre-cancelled pulls win before terminal state, an existing waiter, or buffered data. A stored terminal error is returned exactly to later attachment and non-pre-cancelled pull attempts.

Explicit cancellation, task cancellation before acknowledgement commit, timeout, discovery failure, transport termination, protocol failure, ingress overflow, and final-handle release converge on one cleanup path. Cleanup invalidates stale deadline and attempt tokens, resumes each waiter at most once, stops ingress, clears partial frames and policy buffers, releases identity metadata, and cancels a started channel at most once.

Task cancellation that arrives after acknowledgement commit cannot use the old admission-attempt token to cancel the admitted session. Only the shared external-handle relay owns cancellation after commit.

## Safe Errors

Admission uses one closed internal error code set. Descriptions are generated only from those codes. Pairing codes, Bonjour names, `vid`, endpoints, interface names, installation IDs, application metadata, certificates, raw Network.framework errors, peer rejection text, wire bytes, and event content are not propagated through admission diagnostics or reflection.

## Handoff to Active Transfer

The admitted core remains in policy negotiation and rejects Event-lane traffic until exactly one internal active runner claims the attachment. That runner preserves the same channel, ingress, decoder, codec, route, relay, and terminal owner while enabling negotiated bidirectional transfer. See [SDK-Active-Event-Pump.md](SDK-Active-Event-Pump.md).

A later `sdk-public-connect` change will claim the process lease before admission and expose supported connection operations and safe public state transitions.
