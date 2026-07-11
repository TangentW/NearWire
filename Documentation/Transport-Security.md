# NearWire Transport Security

## Security Boundary

NearWire's supported network transport is always ordered TCP inside TLS. Core exposes no plaintext connection factory and no switch that disables TLS. V1 fixes both the minimum and maximum protocol version to TLS 1.3, advertises only the `nearwire/1` ALPN token, and enables Network.framework peer-to-peer routing for App and Viewer paths.

The wire frame codec remains transport-neutral. A frame is confidential only after it enters a successfully established secure byte channel. Callers must not send wire bytes through an independently created plaintext `NWConnection` and describe that path as NearWire transport.

## Viewer Identity Ownership

The macOS Viewer supplies a Security `SecIdentity` containing its certificate and private key. Core adapts that value into Network.framework TLS options but does not generate, export, persist, rotate, back up, log, or delete the identity. The later Viewer foundation change owns Keychain lifecycle and recovery.

Viewer parameter construction requires an adapted identity. There is no supported identity-free Viewer server configuration.

`SecureViewerTransport` creates the supported Viewer listener. The wrapper hides the raw `NWListener`, reports its bound port, and delivers events through an internal serial queue targeted at the caller's queue. It exposes one-shot incoming connection wrappers, each of which can create exactly one bounded `SecureByteChannel`. Cancelling the listener closes admission before later or racing incoming wrappers can be claimed. Bonjour service metadata and pairing admission remain later responsibilities.

## App Trust Behavior

The App client installs one fixed verification callback. For each connection, it:

1. obtains the peer `SecTrust` and requires a presented certificate;
2. applies Basic X.509 policy;
3. treats the presented leaf as the only anchor for that evaluation;
4. accepts the connection only when Security evaluation succeeds.

This is connection-local anchoring. The SDK does not persist the certificate, require a system CA, or compare the certificate with an earlier Viewer. That behavior allows a team member to switch Viewers without configuring certificates in the App.

It is intentionally not a trust-all callback: certificate parsing, signatures, validity, and Security evaluation still have to succeed. It is also not strong pre-established Viewer authentication. An active attacker on the local path can present another valid self-signed leaf before the App has an authenticated fingerprint. Mandatory TLS primarily protects confidentiality and integrity against passive observers under this V1 trust model.

The optional SHA-256 leaf fingerprint is diagnostic data only. V1 does not persist it or silently convert it into a pin. A later product decision can add explicit fingerprint confirmation without adding a plaintext mode.

Bonjour instance names and pairing codes are not certificate secrets. They help discovery and admission in a later change, but publishing or matching them does not by itself prove TLS identity.

## Bounded Byte Channel

`SecureByteChannel` internally wraps a mandatory-TLS connection or an injected test driver and owns one connection lifecycle. The public App factory does not accept a caller-created `NWConnection`, so supported callers cannot substitute plaintext parameters. The channel starts once, requests at most one receive at a time, and bounds every receive chunk. Empty nonterminal deliveries, oversized driver deliveries, EOF, and driver faults terminate the channel safely.

The production adapter reports ready only after Network.framework metadata confirms TLS 1.3 and the `nearwire/1` ALPN token. Driver callbacks enter one ordered sequencer, and every receive carries a distinct operation token, so replayed or duplicated callbacks cannot create concurrent receives.

Pending sends are limited by count, total bytes, and single-send bytes. A lock-protected mailbox provides synchronous admission from an actor-isolated session coordinator without requiring an actor hop: success transfers ownership of the bytes to the channel, while rejection leaves the existing FIFO unchanged. Admission checks use overflow-safe accounting under the same lock, including concurrent callers. Exactly one send is in flight, and its completed payload slot is cleared immediately. A failed send clears remaining buffers and is never retried because the sender cannot know how much of an ordered byte stream the peer received. The single-send limit includes the wire format's four-byte length and one-byte lane header, so a maximum legal wire payload still fits as one complete send.

Cancellation is idempotent, clears pending data, cancels the driver once, and invalidates late state, receive, and send callbacks. The channel does not reconnect; a later session layer reconnects with a new epoch and fresh wire state.

Default limits are:

| Limit | Default | Hard maximum |
| --- | ---: | ---: |
| Receive chunk | 64 KiB | 1 MiB |
| Pending sends | 256 | 4,096 |
| Pending send bytes | 4 MiB | 64 MiB |
| Single send | 1 MiB + 5 frame bytes | 16 MiB + 5 frame bytes |
| Connection timeout | 10 seconds | 120 seconds |

## Safe Diagnostics

Transport failures expose stable codes, safe paths, safe messages, and operation-rejected or connection-terminal disposition. Core does not include `NWError` descriptions, certificate bodies, private keys, endpoints, pairing codes, or arbitrary underlying error text in its public transport errors.

## Non-Guarantees

This layer does not implement discovery, pairing admission, Viewer identity persistence, certificate rotation UI, mutual TLS, public-CA hostname validation, persistent pinning, reconnection, retry, event acknowledgement, background execution, storage, or UI. Those responsibilities remain in later roadmap changes.
