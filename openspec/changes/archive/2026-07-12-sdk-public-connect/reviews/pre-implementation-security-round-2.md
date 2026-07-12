# Pre-Implementation Security, Privacy, Performance, Distribution, and Documentation Review — Round 2

## Findings

### HIGH — The required no-UI Keychain constant is deprecated and fails the supported warnings-as-errors build

Evidence:

- `openspec/changes/sdk-public-connect/design.md:146-163,226-235`
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:57-65`
- `openspec/changes/sdk-public-connect/tasks.md:12-13,28-32`
- `NearWire.podspec:27-30`
- Xcode Security `SecItem.h` marks `kSecUseAuthenticationUIFail` deprecated from iOS 14 and macOS 11 and recommends an authentication context with interaction disabled.

Round 1 correctly required an exact non-interactive read. The revised plan implements that as an exact `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` query. However, the value constant is deprecated on every supported NearWire deployment target. The repository's CocoaPods configuration sets `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, so directly referencing the required constant is a deterministic build failure rather than a future cleanup concern.

This was reproduced with the Xcode toolchain against the iOS 16 simulator SDK:

```text
xcrun swiftc ... -target arm64-apple-ios16.0-simulator -warnings-as-errors \
  -typecheck -e 'import Security; let value = kSecUseAuthenticationUIFail; _ = value'

error: 'kSecUseAuthenticationUIFail' was deprecated in iOS 14.0
```

Remediation:

- Replace the deprecated fail value with one reviewed non-interactive contract. The narrowest Security-only option is `kSecUseAuthenticationUI: kSecUseAuthenticationUISkip` on the read query; that value remains available for `SecItemCopyMatching` and does not request UI.
- Define the resulting collision transcript explicitly: a protected matching item is skipped and appears missing, add reports duplicate, the one bounded reread skips it again, and the operation fails closed. It must not regenerate, update, delete, retry, prompt, or treat the second missing result as success.
- If the product instead requires the distinct `errSecInteractionNotAllowed` result, use `LAContext.interactionNotAllowed` through `kSecUseAuthenticationContext`, then add LocalAuthentication.framework to the internal distribution/link audit. Do not suppress or availability-wrap the deprecation warning merely to preserve the old constant.
- Update the exact-dictionary requirements and transcript tests to the selected modern mechanism, and run warnings-as-errors SwiftPM and CocoaPods consumer builds on both iOS 16 and macOS 13.

### MEDIUM — The limit planner proves fit but does not require least-privilege network budgets or disclose the bidirectional memory expansion

Evidence:

- `openspec/changes/sdk-public-connect/design.md:59-72,133-144,213-235`
- `openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:25-45`
- `openspec/changes/sdk-public-connect/tasks.md:8-13,28-32`
- `SDK/Sources/NearWire/NearWirePublicModels.swift:53-95,99-154`
- `Core/Sources/NearWireTransport/WirePrimitives.swift:245-343`
- `Core/Sources/NearWireTransport/SecureTransportPrimitives.swift:63-113`
- `SDK/Sources/NearWire/Session/SDKSessionAdmissionModels.swift:289-369`

The new planner usefully separates draft, record, frame, mailbox, turn, decoder, and incoming-buffer byte domains and requires checked hard bounds. It does not, however, define that each derived capacity is the smallest reviewed value sufficient for the configured draft plus required reservations, nor does it prohibit allocating or encoding synthetic maximum payloads during ordinary connect preflight. A conforming implementation could widen frame, mailbox, or incoming retention to existing hard maxima and still satisfy every stated fit proof.

The resource consequence is security-relevant because V1 negotiates one Event-record maximum for both directions. Raising the App's outbound `buffer.maximumEventBytes` can therefore raise the size of one Event accepted from the Viewer, the decoder/frame budget, and incoming retention. Existing hard ceilings include a 16 MiB Event/frame domain and 64 MiB mailbox and incoming-retention domains, before transient decode objects and bounded public stream buffers. The Viewer is not authenticated under V1, so an active local impersonator may exercise those peer-controlled budgets. Hard maxima prevent unbounded growth inside each lower layer, but they do not make unnecessary widening or the cross-layer peak inexpensive.

Remediation:

- Specify deterministic closed formulas for every derived limit. Preserve reviewed defaults where they are already sufficient and otherwise raise each value only to the smallest capacity needed for one maximum outbound Event, exact frame overhead, two maximum Control reservations, and one maximum negotiated incoming record. Reject the configuration before lease claim if any required value crosses a hard maximum.
- Require production planner work to be constant-space and bounded constant-time checked arithmetic over fixed schema constants. Real maximum encodings belong in validation fixtures; `connect` must not construct, allocate, or encode content proportional to a configured multi-megabyte maximum.
- Add a peak-retention audit covering the simultaneous queued draft, envelope/record construction, encoded frame, secure mailbox, decoder/frame work, incoming FIFO/in-flight item, and public stream buffering. Keep the lower-layer independent limits explicit rather than presenting one number as a total-memory guarantee.
- Document that `buffer.maximumEventBytes` influences the symmetric negotiated wire maximum and therefore the maximum peer Event and memory/CPU exposure. If that coupling is not acceptable, keep a conservative fixed network ceiling and reject larger connect-time buffer configurations until a separately reviewed downlink-byte setting exists.
- Add hostile-boundary tests for a maximum single incoming Event, a maximum legal batch, repeated frames until bounded overflow termination, and a maximum outbound candidate, asserting exact derived values, no planner-proportional allocation, no plaintext/reconnect fallback, and cleanup of every charged buffer.

## Round 1 Resolution Verification

All five Round 1 findings were materially remediated in the revised artifacts:

1. **Keychain and random identity:** permanent service/account literals, data-protection selection, explicit device-only accessibility, exact 36-byte canonical lowercase V4 UUID validation, one 16-byte `SecRandomCopyBytes` operation, RFC version/variant bits, bounded duplicate reread, and exact transcript tests are now normative. The deprecated no-UI value is the remaining implementation blocker reported above, not a return to implicit defaults.
2. **Off-actor Security work:** one bounded-call non-actor worker is specified. It retains no NearWire actor, pairing code, metadata, Event, endpoint, certificate, or lease. Cancellation and shutdown detach public state while the attempt keeps the lease until the non-cancellable IPC returns; stale results cannot start discovery or affect newer ownership.
3. **Pairing minimization:** public-orchestrator ownership ends immediately after admission construction, and connected, terminal, and cleanup owners retain no code. The plan correctly promises reference release rather than secure Swift String zeroization.
4. **Metadata and threat disclosure:** public documentation must enumerate automatic hello fields, stable-ID persistence/correlation, public pairing semantics, the active-local-impersonator threat, `viewerIdentityMismatch` limitations, and the fact that connect proves transport/policy activation rather than Viewer identity or Event delivery.
5. **Lease failure accuracy:** cancellation-to-terminal cleanup now retains the exact lease, and all artifacts distinguish deterministic release invocation from successful Objective-C runtime synchronization. Failed claim/release synchronization remains fail-closed with no repair or reacquisition promise.

## Verified Strengths

- Public detachment no longer creates a cancellation-to-terminal lease gap. Identity, admission, admitted attachment, active handle, and cleanup owners retain exact ownership until the relevant operation or permanent core is terminal.
- The attempt state machine has one reasoned cancellation latch, generation-tagged target replacement, transfer-commit boundary, stale-result disposal, and explicit task-cancellation versus shutdown winner semantics.
- Cleanup and terminal Tasks retain no NearWire actor, pairing code, metadata, endpoint, certificate, Event, or internal error. Failure to observe terminal intentionally holds the single process lease fail-closed rather than starting overlapping work.
- Keychain reads and writes remain finite: one read, optional one random request and add, and at most one duplicate reread, with no update, delete, retry, sleep, poll, public identity surface, or caller-selected access group.
- Bundle metadata uses actual `Bundle.main` Strings only, fixed fallback order, existing wire validators, omission of invalid values, and no arbitrary property-list stringification or diagnostic forwarding.
- Mandatory TLS 1.3, fixed ALPN, peer-to-peer-enabled routing, no plaintext fallback, and connection-local leaf evaluation remain intact. The revised plan consistently avoids claiming authenticated Viewer identity.
- Public errors remain fixed and content-safe. Security queries, OSStatus values, identities, metadata, pairing/Bonjour data, endpoints, certificates, Events, internal descriptions, object identities, and addresses are excluded.
- No reconnect, background execution, lifecycle observer, recurring connectivity poll, Event persistence, Viewer trust persistence, third-party dependency, new product, target, or pod subspec is introduced. Existing protocol deadlines and active-pump one-shot token/TTL wakes remain the only connection timers.
- SwiftPM/CocoaPods parity, Security.framework linkage, API inventory, entitlement/privacy-declaration stability, production TLS integration, terminology audit, retention audit, and post-implementation independent review remain explicit gates.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: passed (`Change 'sdk-public-connect' is valid`).
- `git diff --check -- openspec/changes/sdk-public-connect`: passed.
- Xcode iOS 16 simulator warnings-as-errors typecheck of `kSecUseAuthenticationUIFail`: failed as expected with the iOS 14 deprecation diagnostic.
- Xcode host warnings-as-errors typecheck of `kSecUseAuthenticationUIFail`: failed as expected with the macOS 11 deprecation diagnostic.
- Static review of the revised proposal, design, task plan, five capability deltas, all Round 1 findings, current Keychain platform declarations, public buffer/rate configuration, wire/frame/transport/active-pump hard bounds, TLS trust and disclosure model, process lease, terminal ownership, SwiftPM manifest, CocoaPods specification, and documentation/evidence gates.

## Unresolved Count

2 findings remain unresolved: 1 HIGH and 1 MEDIUM.
