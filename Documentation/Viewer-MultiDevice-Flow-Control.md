# Viewer Multi-Device Flow Control

## Scope

The native Viewer accepts up to 16 independently owned App sessions after the separate 32-connection admission boundary. Each accepted connection keeps its original secure channel callback, serial protocol executor, decoder, and terminal gate. Session attachment does not expose or replace Network.framework objects.

This layer completes Hello acknowledgement, negotiates directional Event rates, exchanges Events in both directions, and publishes bounded operational telemetry. Event history, search, filtering, JSON export, control composition, payload inspection, and performance charts remain outside this change.

## Device Ownership and Correlation

The Viewer correlates a logical row by the peer-declared App installation ID plus its optional Bundle ID. These values, App name, version, alias, and local nickname are presentation hints only. They are not authenticated identity and never authorize a connection or retarget queued work.

Only one live connection may own an exact logical route. A second exact route is rejected. The same installation ID with a different or missing Bundle ID is a separate row and does not inherit a Bundle preference, nickname, selection, or downlink queue from another route.

One Viewer owns at most 16 sessions across provisional attachment, policy negotiation, active transfer, and disconnecting cleanup. A slot is released only after the exact admission handle finishes cleanup. Downlink work belongs to the exact connection and session epoch and is never migrated to a reconnect.

After cleanup, safe presentation state may remain in memory for 30 seconds. Recent rows are bounded to 64, evicted deterministically by disconnect time and route key, and serviced by one replaceable expiry wake. They contain no Event payload, queue key, session epoch, endpoint, pairing code, certificate, or wire bytes.

## Policy Negotiation

Viewer defaults request 20 App-to-Viewer Events per second and 10 Viewer-to-App Events per second. The requested policy resolves from a connection-local override, then a bounded Bundle-ID preference, then the global default. The App may accept lower values; those conservative values become effective. Requested and effective values are deliberately shown separately.

Each initial or dynamic offer has one non-resetting 10-second monotonic deadline that starts before encoding and mailbox admission. Only one offer is in flight. Edits during an offer keep the latest desired pair. An acceptance without a pending offer, an escalation, a phase violation, a deadline sample at or after the deadline, or a mailbox failure closes only that session.

Zero pauses the corresponding business Event direction. Control traffic, cleanup, telemetry, and recent-row expiry remain available.

## Queues, Rates, and Atomicity

Each session has an App-to-Viewer delivery queue and a Viewer-to-App send queue. Each queue is limited to 5,000 Events and 16 MiB, with the negotiated maximum Event size as its single-entry limit. Downlink submission supports normal delivery and caller-keyed keep-latest replacement.

Inbound frames validate lane, codec, source, target, epoch, direction, contiguous sequence, Event limits, and receiver-local TTL before committing. A structurally valid record consumes its sequence even when local expiry or overflow discards it. An invalid frame advances no sequence.

Downlink preparation uses value copies of the queue, token bucket, batch scheduler, and sequence counter. The Viewer commits those planned values only after one complete Event or Event-batch frame enters the secure mailbox. A rejected mailbox admission therefore removes no queue entry and advances no sequence. Event traffic reserves one Control mailbox slot and 64 KiB of Control capacity.

Viewer-to-App sends use a 500 ms batch interval. Independent token buckets enforce effective uplink delivery, downlink send, and the cooperative App uplink contract. Business work is bounded per service turn, while Control and the protocol-defined drop summary bypass business Event tokens. Idle sessions have no repeating timer.

Each service turn is partitioned into four 32-record slices for the two expiry queues, local delivery, and downlink batching, so aggregate scheduled business work is at most 128 records before yielding. Active receive handles at most 64 frames, 512 Event records, and 32 system messages per continuation turn. System traffic is limited to 64 messages per second with a burst of 128. The configured input budget defaults to 2 MiB, expands only when a negotiated maximum Event frame plus two receive chunks requires it, and never exceeds the 19 MiB hard maximum.

Local loss is tracked with separate saturating overflow, expiry, keep-latest, and connection-owned-clear counters. Wire summaries preserve overflow, expiry, and coalescing categories; connection-owned clears contribute to the protocol's overflow total because V1 has no dedicated route/terminal field. At most one summary is in flight and one typed aggregate remains pending.

## Receive Backpressure

The internal frame decoder reports one of three bounded outcomes: paused on a complete frame, needs more bytes, or drained. A complete-frame pause retains the ordered frame and suffix inside the existing decoder. During synchronous receive delivery, the connection core claims one generation-bound pause token from `SecureByteChannel`; the channel does not rearm the driver until the retained suffix drains. Approval admission also freezes a partial post-Hello suffix. Attachment resumes the driver for a partial frame or continues an already-complete retained frame without changing its receipt sample.

Only one same-core continuation and one token may exist. Terminal cleanup cancels both, clears decoder bytes, and cannot rearm a stale receive generation. Consumers that never claim a token keep the original eager receive behavior.

## Preferences and Privacy

`ViewerDevicePreferences` stores one versioned record in injected `UserDefaults`. It contains only the requested global policy, at most 256 Bundle-ID policies, and at most 256 logical-route nicknames. Overflow uses deterministic least-recently-written eviction. Corrupt data, unknown schemas, invalid rates, invalid keys, impossible timestamps, and invalid nicknames recover to safe values.

Nicknames are trimmed, contain at most 80 Unicode scalars, and reject control characters. Effective rates, Event drafts, encoded payloads, queue keys, session epochs, queue contents, and recent rows are not persisted.

The existing Viewer privacy manifest remains sufficient: bounded preference storage uses the declared UserDefaults required-reason API, and peer-declared stable correlation remains covered by the documented linked Device ID App-functionality decision. Tracking is disabled.

## Workspace and Operations

The sidebar lists provisional, negotiating, active, disconnecting, and recent devices. The detail pane labels identity as unauthenticated and exposes nickname editing, requested and effective rates, queue count, bytes, oldest wait, current Event throughput, cumulative Event counters, typed local drops, remote-reported drops, and per-device Disconnect.

Pause New Devices and pairing-code refresh affect admission only; they preserve handed-off sessions. Window close, application termination, and identity reset stop transfer first and await every session through the existing cleanup receipt. A slow or invalid App has its own serial executor, queues, tasks, terminal gate, and cleanup path and cannot block another session.

Session terminal presentation uses only these closed local categories: `transportEnded`, `policyTimeout`, `protocolViolation`, `activeWorkLimitExceeded`, `localAdmissionFailure`, `userDisconnected`, and `viewerShutdown`. Arbitrary peer text, transport errors, identifiers, rates, queue values, Event content, and wire bytes are excluded from diagnostic descriptions and reflection.

Uplink consumer execution transfers one Event at a time and is globally capped at 16 operations. Cancellation clears any not-yet-started payload immediately. If a synchronous consumer is already executing and does not return, that single current value is consumer-owned; no remaining batch is retained by the ended session.

## Signing Gate

Unsigned builds cover compilation and behavioral tests but cannot prove the packaged entitlements or cross-update login-Keychain boundary. The stable-signer A/unrelated/B sequence remains explicitly deferred to `release-hardening`, where two configured, unrelated signing identities are required.
