# SDK Pairing Discovery Design

## Context

The iPhone is the Bonjour browser and connection initiator. The Viewer publishes one `_nearwire._tcp` service whose instance name is `NearWire-` followed by a random six-character code. The code is public discovery input rather than a password. It must never become a trust credential, certificate pin, persistent preference, or value copied into diagnostics.

The later active-session change needs one deterministic output: either no matching Viewer, exactly one matching service endpoint, an ambiguous set, or a terminal discovery failure. It must not inherit raw `NWBrowser` callbacks or independently interpret service names.

## Goals and Non-Goals

Goals:

- Normalize and validate pairing-code input without locale-sensitive behavior.
- Derive the one exact expected Bonjour instance name.
- Browse the fixed NearWire service type with peer-to-peer paths enabled.
- Serialize callback updates, deduplicate equivalent results, and select only one exact match.
- Make start, cancellation, and terminal outcomes explicit and idempotent.
- Bound retained result and diagnostic data.
- Keep all production behavior testable through a deterministic injected browser driver.

Non-goals:

- Public connection APIs or UI.
- TCP/TLS connection establishment, Viewer certificate handling, hello negotiation, flow policy, or event transfer.
- Process-wide connection ownership.
- Retry timers, reconnection, background transitions, or app lifecycle observation.
- TXT-record capability negotiation or Viewer display metadata beyond the bounded non-secret `vid` discriminator.
- Authentication, secrecy, throttled password guesses, or persistent pairing-code storage.

## Decisions

### 1. Use one strict pairing-code grammar

The canonical alphabet is `ABCDEFGHJKMNPQRSTUVWXYZ23456789`. A code contains exactly six canonical characters. Raw input is limited to 64 UTF-8 bytes before normalization; validation examines no more than the first 65 bytes and returns one fixed non-echoing error when the limit is exceeded. Input normalization allocates at most the six canonical bytes, removes ASCII hyphen and ASCII whitespace (`U+0009` through `U+000D` and `U+0020`), uppercases ASCII letters without locale rules, and then validates every byte against the alphabet. It rejects Unicode lookalikes, non-ASCII whitespace, punctuation, missing characters, and extra characters.

The validated value, Bonjour constants, and logical service identity live in `NearWireCore` behind `NearWireInternal` SPI so the later Viewer publisher reuses the same grammar. They are Sendable and expose no supported public, Codable, or persistence contract. Pairing-code `description` and `debugDescription` are redacted, including string interpolation, `String(describing:)`, and `String(reflecting:)`; tests inspect canonical bytes through repository-only access.

### 2. Derive one exact service identity

The service type is the fixed `_nearwire._tcp`. The expected instance name is exactly `NearWire-<CANONICAL_CODE>`. Matching is case-sensitive after local normalization and does not accept prefixes, suffixes, Bonjour conflict-renamed instances, or the first service of the correct type.

The SDK does not parse the code back out of arbitrary service names. The caller supplies a validated code and discovery compares results against the derived exact name.

### 3. Separate deterministic discovery from Network.framework

An internal discovery coordinator owns state and consumes driver events. A small internal driver protocol represents start, ready, result snapshots, waiting, failure, and unsolicited cancellation. The production adapter wraps `NWBrowser`; tests use a controllable driver.

Construction performs no work. The one-shot owner contract is `run() async throws -> DiscoveredViewer`; it begins browsing explicitly and completes exactly once. Cancelling the waiting task or calling `cancel()` is idempotent and terminal. `DiscoveredViewer` is internal and Sendable, owns the connectable `NWEndpoint` required by `SecureAppTransport.makeChannel(endpoint:)`, and provides only a redacted safe description. The coordinator resumes its one continuation and immediately releases its own endpoint reference; it never exposes the raw handle through public state or diagnostics.

The operation table is:

| Current state | Operation or driver event | Result |
| --- | --- | --- |
| idle | `run()` | Store one continuation, transition to searching, mark the driver started, then invoke driver start. |
| non-idle | another `run()` | Reject with already-started without replacing the first continuation. |
| idle | `cancel()` | Transition to cancelled without starting or cancelling the driver. |
| searching/waiting | `cancel()` or task cancellation | Transition to cancelled, cancel the started driver once, and resume once with cancellation. |
| searching | ready | Remain searching without duplicate observation. |
| waiting | ready | Recover to searching; a later full snapshot is required before selection. |
| searching | full snapshot | Atomically replace the prior snapshot and evaluate it. |
| waiting | full snapshot | Ignore it as stale until ready is observed. |
| searching/waiting | recognized policy denial | Fail terminally with permission-or-policy denial and cancel once. |
| searching/waiting | ordinary waiting | Enter or remain waiting and keep the browser active. |
| searching/waiting | driver failure | Fail terminally and cancel once. |
| searching/waiting | unsolicited driver cancellation | Transition to cancelled and resume once. |
| terminal | any callback or cancel | Ignore callbacks; cancellation is a no-op. |

State changes to searching before calling the injected driver's start method. A synchronous or reentrant driver callback can only enter the bounded callback ingress and therefore observes initialized coordinator state. A synchronous start throw becomes one terminal browser failure and cancels a possibly partially started driver once. A start/cancel race is serialized by coordinator isolation; whichever terminal transition wins suppresses the other path.

### 4. Treat result updates as bounded snapshots

`NWBrowser` supplies a complete result set per update. At the Network.framework callback edge, the adapter first rejects a raw set above 256 results, then synchronously converts it into lightweight candidates before submitting anything asynchronously. It never queues `NWBrowser.Result`, TXT metadata, raw debug descriptions, or hostile advertised strings. Service instance components are accepted only when they are 1 through 63 UTF-8 bytes; domains are bounded to 255 bytes. Interfaces do not participate in identity or endpoint construction, so the adapter processes at most 32 observations per result and ignores additional observations without discarding an otherwise valid candidate.

The production adapter uses one private serial Network.framework callback queue and maintains a monotonically increasing readiness epoch. Entering waiting invalidates the current epoch and synchronously prevents snapshot conversion. Only a not-ready to ready transition begins a new epoch; a duplicate ready callback while already ready is a no-op. Results are converted only while callback-edge state is ready and carry that epoch. Callback ingress retains at most one event being processed, one latest replacement snapshot, and one pending state/terminal event. It delivers a ready state before a snapshot from the same epoch and discards any snapshot whose epoch is older than the latest waiting or ready event. Result storms coalesce to the latest complete snapshot. The first terminal failure, policy denial, or cancellation is latched, discards pending nonterminal work, and prevents every later enqueue. Tests expose retained event, candidate, and canonical-identity byte counts to prove the bound.

Each update is processed into a temporary candidate collection before coordinator mutation. More than 256 raw results publishes no partial match, clears the previous snapshot, and fails terminally. Conversion has exactly three per-result outcomes: a non-service, unrelated, malformed-identity, non-ASCII, overlong, or hostile result is discarded and increments a safe per-snapshot count; an otherwise valid exact-name result with missing or invalid `vid` becomes one bounded unattributed-exact marker containing no advertised text or endpoint; and an exact-name result with valid `vid` becomes an attributed candidate. The coordinator adds each accepted per-snapshot count into one internal cumulative counter with saturation at `UInt64.max`. Interface observations beyond 32 are ignored and never change one of these identity outcomes. None of these per-result outcomes fails the complete discovery. A valid converted update atomically replaces rather than accumulates prior results. Conversion arithmetic failure is terminal and retains no partial collection.

Service type is accepted ASCII case-insensitively only when it equals `_nearwire._tcp` and is stored as `_nearwire._tcp`. Domain is accepted ASCII case-insensitively only as `local` or `local.` and is stored as `local.`. Empty, non-ASCII, malformed, or non-local values are discarded. Instance names are never case-folded or Unicode-normalized and must equal the locally derived ASCII name byte-for-byte.

One logical service identity is the canonical instance name, type, domain, and required bounded publisher discriminator. The production descriptor requests Bonjour TXT records but synchronously reads only `vid`; all other keys and the raw record are discarded. An exact-name result without a valid `vid` is not matchable and keeps discovery searching until a later complete metadata update. If valid and unattributed exact-name results coexist, discovery also remains searching and returns no generic endpoint.

`ViewerDiscoveryDiscriminator` lives in Core with the pairing grammar. Derivation uses `CryptoKit.SHA256` over the exact validated `EndpointID.rawValue` UTF-8 bytes, with no case folding or other normalization; custom cryptographic implementations are prohibited. `vid` is the first eight digest bytes encoded as 16 lowercase hexadecimal ASCII characters. It remains stable while the Viewer installation ID remains stable, is recomputed when that Keychain identity is reset, and is locally linkable across pairing-code refreshes. A different installation ID is overwhelmingly likely but not guaranteed to produce a different 64-bit prefix; equal discriminators remain indistinguishable. It is public non-secret discovery metadata, not authentication or a certificate binding. Golden vectors include `viewer-installation -> b3a97f874aad08bf` and `00000000-0000-0000-0000-000000000001 -> 7ac1b8d7010bb6cd`.

Interface names and indexes are bounded path observations, not identity. LAN and P2P appearances with the same valid `vid` merge. Two different valid `vid` values under the same exact instance name are distinct publisher registrations and therefore ambiguous.

The matched connectable handle is reconstructed as the interface-neutral service endpoint `NWEndpoint.service(name:type:domain:interface:nil)`, allowing Network.framework to choose the current LAN or P2P path. The adapter never chooses a representative hostile raw endpoint.

The coordinator filters by exact expected instance name:

- zero matches: browsing continues with `searching` state;
- two or more distinct valid publisher discriminators: fails closed as `ambiguous` and stops the browser, even if unattributed markers also exist;
- otherwise, any unattributed-exact marker: continues searching without returning an endpoint, including when one valid registration also exists;
- otherwise, one valid attributed registration: reports `matched` once and stops the browser; interface-only duplicates merge;
- a result removed before selection: no stale endpoint is retained.

On a match, the coordinator stops the browser, transitions to payload-free matched state, resumes `run()` with one `DiscoveredViewer`, and releases the coordinator's candidate snapshot and endpoint reference. A compile-time integration test passes that endpoint directly to `SecureAppTransport.makeChannel(endpoint:)`. Cancellation, failure, and ambiguity release all candidates and the continuation.

### 5. Keep diagnostics safe and actionable

Discovery errors use stable internal codes such as invalid code, already started, result limit exceeded, unavailable network, permission-or-policy denial, browser failure, ambiguity, and cancellation. Operational `DiscoveredViewer` privately carries one endpoint, while errors, state descriptions, interpolation, reflection-safe summaries, and logs never include the canonical code, advertised name, raw `NWError`, endpoint, interface name, TXT data, or application content.

Network.framework error classification is conservative. A recognized policy-denied DNS waiting error is terminal permission-or-policy denial because the App cannot recover without an external Settings change. Other waiting errors are nonterminal unavailable-network state and can recover only through a later ready callback. A browser failed state is terminal. Unknown errors use one fixed browser-failure diagnostic.

### 6. Do not create hidden lifetime work

This change adds no retry timer and no process-global registry. The coordinator and driver are owned by a later NearWire session object. Cancellation releases callbacks and result snapshots. Deinitialization is defensive cleanup, not the primary lifecycle API.

## Test Strategy

- Table tests cover every valid alphabet byte, normalization separators, length boundaries, lowercase ASCII, Unicode lookalikes, control characters, and redaction.
- Discovery tests cover empty, exact, wrong-name, wrong-type, wrong-domain, duplicate-interface, same/different/missing/invalid `vid`, ambiguous, oversized, reordered, removed, late, failed, waiting, ready recovery, cancelled, and repeated lifecycle callbacks.
- Concurrency tests cover cancel-before-start, repeated run in every state, reentrant start callbacks, start failure, unsolicited driver cancellation, and result/cancellation races with one completion.
- Production-plan tests inspect the fixed TXT-enabled service descriptor and peer-to-peer browser parameters without requiring live network discovery.
- Existing SwiftPM/CocoaPods public consumer and API-inventory gates prove the supported facade remains unchanged.

## Risks and Trade-offs

- Bonjour may expose one service on more than one interface. Logical identity deliberately ignores interface path observations, and the interface-neutral endpoint lets Network.framework select the current path.
- A six-character code can collide. Distinct valid `vid` values present in the same snapshot provide best-effort collision detection, and the Viewer is responsible for refreshing a conflicted code. Missing, invalid, identical, or spoofed values and changes between discovery and DNS-SD resolution can remain indistinguishable; neither `vid` nor result count is a security decision.
- Permission denial is not uniformly reported across OS versions. Safe classification remains conservative and never treats an unknown error as proof of denial.
- Stopping after one exact match means path changes are owned by the later connection and reconnection changes, not by a browser that continues in parallel.

## Migration Plan

1. Add validated pairing-code and service-identity values with tests.
2. Add the driver-independent discovery coordinator and adversarial lifecycle tests.
3. Add the Network.framework adapter and inspectable browser plan.
4. Update SDK integration documentation and the refined roadmap.
5. Run all gates and independent review rounds to zero findings, archive, and commit before active-session work begins.

## Open Questions

None. Public connection semantics, installation identity, session handshake, reconnect policy, and background behavior remain explicit later changes.
