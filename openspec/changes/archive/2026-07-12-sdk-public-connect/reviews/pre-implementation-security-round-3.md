# Pre-Implementation Security, Privacy, Performance, Distribution, and Documentation Review — Round 3

## Findings

No actionable finding remains in the revised pre-implementation artifacts.

## Round 2 Resolution Verification

### Modern non-interactive Keychain access is complete

The deprecated `kSecUseAuthenticationUIFail` contract has been replaced everywhere with the supported read-only query pair `kSecUseAuthenticationUI: kSecUseAuthenticationUISkip`. Deprecated authentication constants and warning suppression are explicitly forbidden.

The plan now defines the security-relevant protected-item transcript rather than treating `UISkip` as ordinary absence:

1. the protected matching item is skipped and the first read appears missing;
2. one generated candidate is offered once and add returns duplicate;
3. the single allowed reread skips the protected item again;
4. identity construction fails closed without another generation, add, retry, update, delete, prompt, or status disclosure.

The exact read dictionary, add dictionary, permanent service/account literals, data-protection selection, device-only accessibility, canonical 36-byte lowercase V4 UUID validation, one 16-byte `SecRandomCopyBytes` operation, RFC version/variant transformation, duplicate bound, and transcript call counts remain normative in the design, capability spec, and tasks.

Warnings-as-errors typechecks of the actual query expression passed for both deployment families:

```text
arm64-apple-ios16.0-simulator: passed
arm64-apple-macosx13.0: passed
```

No LocalAuthentication dependency, availability workaround, or deprecated-symbol suppression is needed.

### Network limits are fixed, least-privilege, and constant-space

The negotiated Event-record maximum no longer derives from `buffer.maximumEventBytes`. It is one fixed deterministic-content bound plus a checked exact maximum for all non-content V1 record syntax and values. The specification requires a structural proof that the production content representation is embedded without hidden expansion and adversarial/property validation through the production encoders.

Every downstream capacity is now `max(reviewedDefault, exactRequiredValue)` rather than a convenient hard maximum. Only active-turn queue accounting may increase with the offline buffer setting; the symmetric peer Event maximum, frame, decoder, transport, and incoming exposure do not. Unsupported arithmetic or hard-bound composition fails before instance token, lease, Keychain, discovery, or state work.

Ordinary connect preflight is explicitly bounded constant-time and constant-space and may not allocate or encode a synthetic maximum payload. Production encoder work belongs only to validation fixtures. Required hostile-peer evidence covers maximum single Events, maximum legal batches, repeated frames through bounded overflow termination, cleanup, and absence of plaintext or reconnect fallback. The peak-retention audit separately accounts queued drafts, temporary records, frames, mailbox storage, decoder work, incoming FIFO/in-flight work, and each public subscriber buffer without presenting any one component as a total-process memory bound.

The public security disclosure also states that the fixed symmetric peer Event bound has bounded CPU and memory exposure. This closes the Round 2 performance and unauthenticated-peer documentation issue.

## Ownership and Terminal Review

- Admission creates one shared `SDKSessionLifetime` with the permanent cancellation relay and exactly one one-shot termination value. Admitted session, attachment, and active handle share it; no layer may replace it.
- Immediately after admission, one `SDKPublicTerminalCoordinator` receives the exact lease and starts the sole wait before pump attachment. Attempt and connected owners retain the coordinator but never register another wait.
- Shutdown and deinitialization request cancellation through the current internal owner and drop their edge. They neither move the termination value nor create a new Task, so there is no cancellation-to-terminal lease gap or duplicate release authority.
- The coordinator Task self-retains only the bounded coordinator graph and has no strong NearWire, pairing-code, metadata, endpoint, certificate, Event, or arbitrary-error edge. A terminal result releases once and sends only a weak tokenized callback. A terminal wait that never completes intentionally retains the one process lease fail-closed; it does not create a retry, polling loop, or growing task family.
- The permanent core captures App rates by value and removes strong `activeOwner` storage. Every live owner operation captures NearWire weakly and returns a closed owner-unavailable outcome when the actor is gone. Existing operation-gate and exact wake-token cleanup remain authoritative.
- Required retain-graph evidence covers the core, live-operation closures, callback ingress, channel, coordinator, termination Task, wake registration, and pairing data. It distinguishes a pending connect Task legitimately retaining NearWire from post-success external release, which must deinitialize NearWire, release the hidden handle, cancel the core, reach terminal, and release through the same coordinator.
- Runtime claim/release synchronization failures remain accurately fail-closed. State, shutdown, deinitialization, and retry never promise repair or reacquisition, and stale exact-token release cannot affect a newer owner.

## Security, Privacy, and Documentation Review

- Pairing data is retained only through admission/discovery handoff. Connected owners, the terminal coordinator, Tasks, Keychain, Events, public values, reflection, logs, and diagnostics retain none. The plan promises reference release rather than impossible secure zeroization of Swift String storage.
- The installation UUID is documented as a device-only, non-migrating Viewer correlation label, not a credential. Its stable cross-session disclosure and absence of a reset API are required public documentation.
- Bundle metadata accepts only actual bounded `Bundle.main` Strings with exact fallback order. Invalid values are omitted and arbitrary property-list objects are neither stringified nor diagnosed.
- Mandatory TLS 1.3, fixed ALPN, peer-to-peer-enabled routing, and no plaintext fallback remain unchanged. Documentation explicitly says the pairing code is not a password, V1 does not authenticate a pretrusted Viewer, an active local impersonator remains in scope, and `viewerIdentityMismatch` is only Bonjour-to-hello consistency.
- Successful connect is consistently defined as transport and initial-policy activation, not authenticated Viewer identity, Event receipt, persistence, acknowledgement, or delivery. Post-return terminal reasons produce only disconnected and create no hidden public error-history surface.
- Public diagnostics remain closed and fixed. Pairing/Bonjour data, endpoints, interfaces, certificates, installation identity, Bundle metadata, Events, protocol values, Security dictionaries, OSStatus values, object identities, memory addresses, and underlying descriptions are excluded.
- Host local-network declarations remain a host-App responsibility already documented by the discovery layer. This change adds no Keychain-sharing entitlement, public Security type, third-party dependency, product, target, pod subspec, reconnect, background execution, lifecycle observer, recurring connectivity poll, persistence, logging, analytics, UI, or performance collection.

## Distribution and Evidence Gates

- SwiftPM and CocoaPods must compile the same iOS 16 Swift 5 consumer surface and prove Security.framework linkage without exposing implementation types.
- Full strict-concurrency, production TLS, package, CocoaPods, API inventory, boundary, structure, English, formatting, version, validation-tool, and strict OpenSpec gates remain required.
- Evidence must include exact Keychain dictionaries and call transcripts, constant-space formulas and peak retention, hostile-peer boundaries, one-wait/one-release terminal outcomes, weak retain graphs, task/timer inventory, fail-closed lease-runtime failures, terminology checks, entitlement/privacy-declaration stability, and requirement-to-evidence mapping.
- Independent post-implementation security/performance/documentation review remains mandatory before archive.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: passed (`Change 'sdk-public-connect' is valid`).
- `git diff --check -- openspec/changes/sdk-public-connect`: passed.
- Xcode warnings-as-errors typecheck of `[kSecUseAuthenticationUI: kSecUseAuthenticationUISkip]` for `arm64-apple-ios16.0-simulator`: passed.
- Xcode warnings-as-errors typecheck of `[kSecUseAuthenticationUI: kSecUseAuthenticationUISkip]` for `arm64-apple-macosx13.0`: passed.
- Static review of the complete revised proposal, design, tasks, six capability deltas, all Round 1 and Round 2 findings, current Security declarations, Keychain and CSPRNG contract, public content/buffer/rate limits, wire/frame/transport/active-pump bounds, shared lifetime and termination primitive, process lease, weak owner graph, TLS trust model, package manifest, CocoaPods specification, discovery host declarations, and documentation/evidence gates.

## Unresolved Count

0 findings remain unresolved. Security, privacy, performance, distribution, and documentation planning closure is granted for pre-implementation Round 3.
