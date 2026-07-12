# Pre-Implementation Security, Privacy, Performance, Distribution, and Documentation Review — Round 1

## Findings

### HIGH — The Keychain and random-identity contract leaves security-critical behavior to implicit platform defaults

Evidence:

- `openspec/changes/sdk-public-connect/design.md:99-115,176-183`
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:26-30,47-51`
- `openspec/changes/sdk-public-connect/tasks.md:8-11,23-27`

The plan requires a fixed generic-password service and account, but it does not define their immutable literal values or the exact read and add dictionaries. More importantly, it explicitly adds no accessibility override. That leaves the item's lock-state availability, device migration and backup behavior, and macOS data-protection Keychain selection to implicit defaults rather than an approved product contract. The plan also does not require non-interactive reads, so an old or colliding item protected by an access-control policy could cause an unexpected authentication prompt in a connection API that otherwise has no UI scope.

The data and randomness formats are similarly incomplete. “Canonical lowercase UUID” does not define an exact 36-byte UTF-8 payload check, RFC 4122 variant/version validation, or a CSPRNG operation. `UUID()` does not expose random-generation failure, while the specification and tests require that failure to be handled. Without one exact algorithm, production and the injected tests can validate different behavior, and package versions can accidentally split the stable identity by changing service/account strings or encoding.

Remediation:

- Define permanent, version-independent service and account literals and require the same values through SwiftPM, CocoaPods, and independently loaded SDK images. State the compatibility/migration rule: the constants cannot be changed without a coordinated migration.
- Specify exact `SecItemCopyMatching` and `SecItemAdd` dictionaries: generic-password class, exact service and account, one result, returned data only, no synchronizable or access-group key, data-protection Keychain selection, and authentication UI failure rather than prompting.
- Choose and document one explicit accessibility class. For this foreground-only, device-local label, prefer `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` unless the product intentionally wants backup/device migration; whichever class is selected must be a reviewed requirement rather than a default.
- Require stored data to be exactly the canonical 36-byte lowercase UTF-8 representation before constructing the UUID. Define whether pre-existing values must also be RFC 4122 version 4 with the RFC variant and test the chosen rule.
- Generate 16 bytes with `SecRandomCopyBytes`, fail on any non-success status without a weaker fallback, set the UUID version-4 and RFC-variant bits, and serialize once to the canonical lowercase form. The injected production seam must model these same operations, not a looser test-only abstraction.
- Add exact-query tests, accessibility/data-protection/no-UI assertions, byte-length and canonicality tests, stable-literal audits, and fixed safe mapping for every relevant `OSStatus`. No query, status, UUID, service/account value, or returned object may enter diagnostics or reflection.

### MEDIUM — Synchronous Security.framework calls can block the NearWire actor and defeat responsive cancellation or shutdown

Evidence:

- `openspec/changes/sdk-public-connect/design.md:11,17-22,88-97,161-168`
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:42-49,110-125`
- `openspec/changes/sdk-public-connect/specs/sdk-async-facade/spec.md:3-20`
- `openspec/changes/sdk-public-connect/tasks.md:15-19`

Keychain calls are synchronous IPC and are not task-cancellable. The planned order puts identity construction after the lease claim but does not say whether those calls execute directly on the actor. If they do, a slow Security operation prevents `shutdown()` and other actor work from running, keeps the process lease live, and cannot observe the attempt relay until the system call returns. Disabling authentication UI removes the worst prompt case but does not make the IPC duration SDK-bounded.

Remediation:

- Run the complete identity operation in one bounded, non-actor worker with immutable fixed inputs. It may perform only one read, an optional one random generation and add, and at most one duplicate reread; it must not retry, sleep, poll, or retain the NearWire actor, pairing code, Events, metadata, endpoint, or lease.
- Keep the exact attempt token authoritative. Cancellation or shutdown may detach the attempt and release its exact lease while the non-cancellable system call finishes; any later worker result must be token-stale and unable to start discovery, publish state, install an owner, or release a newer lease.
- Account for this worker in the task/retention audit and add deterministic barriers for cancellation and shutdown during read, add, and duplicate reread. Prove bounded call counts, no actor retention, no post-cancellation discovery, and no lease or worker-result leak.
- If the project deliberately accepts actor blocking instead, state that limitation and weaken the current responsive cancellation/cleanup language accordingly; the preferred SDK behavior is isolation from the actor.

### MEDIUM — The connected owner retains the pairing code despite having no post-admission use

Evidence:

- `openspec/changes/sdk-public-connect/design.md:24-32,92-97,153-159,185-187`
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:47-51,110-135`
- `openspec/changes/sdk-public-connect/tasks.md:16-19`
- `Documentation/SDK-Discovery.md:38-48`

The pairing code is public Bonjour discovery metadata rather than a password, but it is still a correlation value supplied by the App. This change intentionally performs no reconnect, code getter, code change, lifecycle policy, or retained-code retry. After exact discovery and admission consume it, transferring it into the active owner provides no function and retains it for the entire potentially long-lived session. That conflicts with data minimization and enlarges the ownership graph without improving security or behavior.

The repeated promise to “clear” the code must also not imply secure zeroization. Swift `String` and intermediate normalization copies cannot be guaranteed to be overwritten; the implementable guarantee is that NearWire releases all owned references and never persists, renders, logs, reflects, or transmits the value as an Event.

Remediation:

- Keep the normalized code only in the attempt/admission ownership needed for discovery, release all public-orchestrator references as soon as admission no longer needs them, and remove the code from `SDKPublicConnectedSession` and terminal cleanup requirements.
- Let the later lifecycle change make a new explicit retention decision if reconnect is added; do not retain now for speculative future policy.
- Replace zeroization-sounding documentation with an exact logical-retention guarantee and add ownership/reflection/deinitialization tests proving the active owner and terminal Task contain no code.

### MEDIUM — The public documentation task does not explicitly disclose identity and App-metadata exposure under the unauthenticated Viewer model

Evidence:

- `openspec/changes/sdk-public-connect/design.md:42,76,99-115,129-151,170-183`
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:26-45,94-108`
- `openspec/changes/sdk-public-connect/tasks.md:23-27`
- `Documentation/Transport-Security.md:17-32`
- `Documentation/SDK-Discovery.md:38-48`
- `Core/Sources/NearWireTransport/WireControlPayloads.swift:7-21,63-83`

The existing transport documentation correctly says that V1 connection-local leaf anchoring encrypts the connection but does not authenticate a pre-established Viewer identity. An active local attacker can present a different valid self-signed leaf. The pairing code and `vid` are public and spoofable, so they do not close that gap. The public-connect plan then automatically sends a stable Keychain installation identifier plus Bundle identifier, display name, and version in the App hello, followed by arbitrary App Events when admitted.

The design mentions the connection-local limitation, but task 4.3 only generically asks for security documentation. It does not require the public API and README to say what metadata is disclosed, that the stable identifier enables Viewer-side correlation across sessions, or that `viewerIdentityMismatch` is only discovery-to-hello consistency rather than authenticated identity. “Encrypted session” and “secure connection” are accurate only as transport properties and can otherwise be read as authenticated peer claims.

Remediation:

- Make the public documentation task explicitly state that the pairing code is not a password, V1 does not authenticate the Viewer, an active local attacker remains in scope, and successful `connect` means TLS 1.3 transport plus initial policy activation—not trusted Viewer identity or Event receipt.
- Document every automatically transmitted hello field, the installation identifier's Keychain persistence and correlation purpose, the absence of a reset API in this change, and the selected backup/device-migration behavior implied by the accessibility class.
- Define metadata acquisition precisely from `Bundle.main`: accept only actual `String` values, apply the exact existing UTF-8/ASCII wire bounds, define whether an invalid primary falls back or is omitted, and never stringify arbitrary property-list objects. Omitted optional fields must not appear in diagnostics.
- Describe `viewerIdentityMismatch` as a best-effort Bonjour-to-hello disagreement signal and not certificate, account, or cryptographic identity verification. Add a terminology audit that rejects stronger authentication claims from README, API comments, error messages, and connection documentation.

### MEDIUM — Lease cleanup promises overstate the existing fail-closed runtime guarantee

Evidence:

- `openspec/changes/sdk-public-connect/proposal.md:7-12`
- `openspec/changes/sdk-public-connect/design.md:13-22,92-97,161-168`
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:110-131`
- `openspec/specs/sdk-process-connection-lease/spec.md:10-12,39-63,74-76`
- `Documentation/SDK-Connection-Lease.md:20-26`

The new plan repeatedly says ownership is released on every failure, shutdown, deinitialization, and terminal path. The canonical lease contract is intentionally narrower: every path must invoke exact-handle release, but a failed runtime enter can leave the slot untouched and a failed exit provides no successful-clear or later-reacquisition guarantee. A claim-exit failure can also have installed a token without returning a handle. The public plan must not promise resource release or retry availability that the approved low-level primitive cannot prove under Objective-C runtime synchronization failure.

Remediation:

- Align proposal, design, capability delta, public docs, and audit wording with the canonical lease contract: every owner deterministically invokes idempotent exact-handle release; successful runtime synchronization clears ownership; synchronization failure remains fail-closed and may leave connection ownership unavailable for the process lifetime.
- Keep `connectionOwnershipUnavailable` distinct from ordinary contention and never suggest that retry, shutdown, deinitialization, or App-side reset can repair the runtime failure.
- Add injected claim-exit, release-enter, and release-exit failure coverage at the public orchestration boundary. Assert safe fixed diagnostics, no discovery/Keychain work after a failed claim, no newer-token release, and no unsupported reacquisition claim.

## Verified Strengths

- The connection remains an explicit instance operation. Construction and ordinary Event APIs start no lease, Keychain, discovery, permission, transport, task, timer, persistence, or background work.
- Pairing normalization precedes the process lease, and the lease precedes Keychain, Bonjour discovery, TLS, and active pumping. Same-instance overlap is rejected before global work, while cross-instance and cross-image ownership use the existing exact-token lease.
- Mandatory TLS 1.3, fixed ALPN, peer-to-peer-enabled routing, connection-local certificate evaluation, no plaintext fallback, and the absence of persistent Viewer trust are inherited rather than reimplemented. The current transport and discovery documentation accurately avoids claiming Viewer authentication.
- Public errors are a closed, fixed-message boundary and explicitly exclude underlying system text, pairing codes, Bonjour data, endpoints, certificates, installation identifiers, Bundle metadata, Events, and protocol payloads.
- The active terminal observer retains only its one-shot observer and token and captures NearWire weakly. No recurring connectivity poll, reconnect loop, lifecycle observer, or background policy is introduced; existing active-pump queues, ingress, transport mailboxes, protocol deadlines, and one-shot rate/TTL wakes retain their reviewed bounds.
- The proposed default Keychain item uses no synchronizable storage, cloud sync, caller-selected access group, overwrite, delete, reset, or public identity API. The missing details above can be added without broadening that surface.
- SwiftPM and CocoaPods already use Swift 5 language mode and iOS 16 for the supported consumer path. Security and Network types remain internal, no third-party dependency is added, and the default application Keychain access group requires no new sharing entitlement. Final gates still need to prove both consumer binaries link with Security.framework and that no entitlement or privacy-manifest declaration change is required under the selected Keychain attributes.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: passed (`Change 'sdk-public-connect' is valid`).
- Static review of the complete proposal, design, task plan, five capability deltas, canonical lease contract, current TLS trust model and documentation, pairing/discovery privacy model, Wire hello validation, active-pump ownership/resource boundaries, Swift Package manifest, CocoaPods specification, and the requested distribution and documentation gates.

## Unresolved Count

5 findings remain unresolved: 1 HIGH and 4 MEDIUM.
