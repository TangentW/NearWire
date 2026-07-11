# Core Transport Security Design

## Context

The V1 wire codec is deliberately network-neutral. This change supplies the shared secure transport substrate used later by the iOS SDK client and macOS Viewer listener. NearWire is internal tooling with frequent Viewer switching and no service configuration, so the previously selected NSLogger-like trust model prioritizes mandatory encryption and zero App-side certificate setup over persistent Viewer pinning.

That trade-off must remain explicit: a self-signed Viewer certificate accepted for one connection protects against passive observation but, without a pre-established fingerprint or secret, does not by itself defeat an active local-network impersonator. Bonjour instance names and pairing codes are discovery/admission inputs in a later change, not certificate authentication material.

## Goals / Non-Goals

**Goals:**

- Make plaintext construction impossible through the supported transport API.
- Use ordered Network.framework TCP with TLS 1.3, V1 ALPN, and peer-to-peer routing enabled.
- Adapt caller-owned Viewer identities without generating or persisting keys in Core.
- Validate a presented leaf certificate as a connection-local anchor through one fixed client trust policy.
- Bound receive chunks, queued send operations, and queued send bytes before retaining caller data.
- Provide deterministic injected-driver tests for ordering, faults, cancellation, late callbacks, and resource exhaustion.

**Non-Goals:**

- Bonjour service attachment or browsing, pairing-code normalization, admission UI, process connection leases, or multi-device session ownership above the secure Viewer listener.
- Viewer identity generation, rotation UI, Keychain storage, backup, or migration.
- Persistent App-side certificate pinning, public CA hostname validation, mutual TLS, PSK, or pairing-code-derived keys.
- Reconnection, retry, event ACK, message parsing, timers owned by the SDK facade, or background lifecycle policy.
- The supported application-facing SDK facade.

## Decisions

### 1. One mandatory secure parameter plan

Core defines a validated immutable plan and a Network.framework adapter. The plan always selects ordered TCP plus TLS, fixes minimum and maximum protocol to TLS 1.3, advertises only `nearwire/1` through ALPN, enables `includePeerToPeer`, and applies a bounded TCP connection timeout.

There is no boolean for TLS, no plaintext initializer, and no fallback parameter set. Failure to configure TLS, identity, trust, or ALPN fails construction before a connection starts.

### 2. Separate App client and Viewer server roles

Viewer parameters require a non-null caller-supplied identity adapted from `SecIdentity`. App client parameters never carry a local identity and always install the fixed Viewer-leaf trust evaluator. Role-specific factories prevent accidentally starting a Viewer without a certificate or installing the permissive self-signed policy on the server side.

### 3. Keep identity ownership outside Core

`ViewerTransportIdentity` retains the Security identity only long enough to configure TLS. Core never writes the Keychain, exports private key material, logs certificate bytes, or generates certificates. The future Viewer foundation change owns creation, persistence, rotation, and recovery.

The supported Viewer entry point creates an identity-required `SecureViewerListener`, never exposes its raw `NWListener`, and delivers one-shot incoming wrappers. Each wrapper can create one bounded `SecureByteChannel`; listener cancellation closes admission so a racing incoming wrapper cannot start after shutdown.

### 4. Use connection-local leaf anchoring, not trust-all

The client verify callback copies `SecTrust`, requires a presented leaf, installs a Basic X.509 policy, anchors that leaf for this evaluation only, requires anchor-only evaluation, and completes with the evaluation result. It records only a SHA-256 certificate fingerprint for diagnostics when requested; it does not persist or compare the fingerprint in V1.

This accepts a structurally and temporally valid self-signed Viewer leaf without App configuration. It is not a `completion(true)` trust-all callback and does not disable certificate parsing or validity checks. It also is not strong Viewer authentication. Documentation and error text must preserve that distinction.

### 5. Put bounded byte lifecycle above an injected driver

`SecureByteChannel` owns a small explicit state machine: setup, preparing, ready, closing, terminal failure, and cancelled. A driver protocol represents the subset of NWConnection needed for start, state updates, one-shot receive, send completion, and cancel. The production adapter owns NWConnection, verifies negotiated TLS 1.3 and `nearwire/1` metadata before reporting ready, and feeds callbacks through one ordered ingress; tests use deterministic fakes.

Only one receive request may be outstanding. Each receive is capped at the configured chunk bound and delivered synchronously into a caller callback/async stream bridge without accumulating an unbounded frame array. EOF, nil-data anomalies, oversized driver delivery, and errors become one terminal result.

### 6. Bound and serialize sends before retaining data

Configuration limits pending send count and total bytes. Admission uses overflow-safe accounting and rejects an item atomically before copying/retaining it when either limit would be exceeded. Exactly one send is in flight; successful completion clears its payload slot immediately and advances FIFO order. A send error fails the channel, releases all pending buffers, and ignores late completions by generation.

Wire payload limits exclude the four-byte length and one-byte lane header, so the corresponding complete-frame single-send limits include those five bytes. Exact default and hard-bound frames therefore remain admissible without stream fragmentation.

The byte channel does not retry because retry would duplicate an unknown prefix of an ordered stream. Higher session work reconnects with a new epoch and fresh protocol state.

### 7. Make cancellation and callbacks idempotent

Start is single-shot. Cancel is idempotent from every nonterminal state, cancels the driver once, clears pending sends, and emits one terminal cancellation. State, receive, and send callbacks carry a generation/token so callbacks arriving after cancellation or failure cannot restart receives, complete a newer send, or emit a second terminal event.

### 8. Keep failures safe and transport-specific

Transport errors expose stable codes, operation/connection disposition, and bounded safe context. NWError descriptions, certificate bodies, endpoint metadata, pairing codes, private keys, and arbitrary underlying errors are not serialized or logged by default.

## Risks / Trade-offs

- **No pre-established Viewer authentication** → Document encryption-only identity assurance; a later opt-in fingerprint confirmation can strengthen it without changing mandatory TLS.
- **TLS 1.3 excludes unusually old peers** → Product baseline is iOS 16/macOS 13, where TLS 1.3 is available; failing closed is preferable to silent downgrade.
- **Connection-local anchoring accepts a valid attacker leaf** → Pairing/admission reduces accidental cross-connection but is not claimed as cryptographic authentication.
- **Bounded send queue can reject bursts** → Surface deterministic backpressure so existing flow control can retain or drop according to policy.
- **Injected driver differs from NWConnection runtime** → Keep the adapter thin and add parameter/identity/trust integration tests on Apple platforms.

## Migration Plan

1. Add specifications, transport values/errors/limits, TLS plan, identity/trust adapter, driver protocol, NWConnection adapter, and bounded channel.
2. Add deterministic unit, fault-injection, resource, concurrency, and platform integration coverage plus English security documentation.
3. Run complete validation and independent remediation rounds to zero findings.
4. Archive and commit before `sdk-public-api` enters apply.

Rollback is a normal commit revert because no SDK or Viewer session consumes the new transport substrate yet.

## Open Questions

None. Persistent identity lifecycle, Bonjour metadata, pairing admission, reconnection, and optional authenticated fingerprint UX remain explicitly assigned to later changes.
