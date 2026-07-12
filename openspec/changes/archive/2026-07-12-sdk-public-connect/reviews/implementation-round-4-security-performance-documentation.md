# SDK Public Connect Implementation Review — Round 4 Security, Performance, and Documentation

## Scope

This final review examined the current remediated worktree, active specifications and tasks, all prior security/performance/documentation findings, final evidence, preserved aggregate summaries, and the final lock-discipline remediation. It revalidated process-lease fail-closed behavior, pairing retention, Keychain access, safe errors, TLS claims, deterministic resource bounds, package linkage, public boundaries, documentation, and evidence provenance. No production, test, specification, task, or existing evidence file was modified.

## Result

**Unresolved actionable finding count: 0.**

No security, privacy, performance, resource-bound, Keychain, pairing-retention, TLS, packaging, documentation, or evidence-provenance finding remains in this review dimension.

## Prior-Finding Disposition

### Round 3 discovery terminology — resolved

- `Documentation/SDK-Discovery.md:7` now says the browser is started by its session owner, with no future-owner implication.
- `Documentation/SDK-Discovery.md:48` now calls TLS and protocol admission downstream layers.
- `Documentation/SDK-Discovery.md:67` clearly separates discovery's own non-guarantees from the current public coordinator composition and reserves only disconnect, reconnection, and background lifecycle policy for later work.
- A repository documentation search found no remaining stale `future session owner`, `later TLS`, `future terminal`, or public-connect-absent wording.

### Round 3 run identity and aggregate provenance — resolved

- `openspec/changes/sdk-public-connect/evidence/run-identity.md:3-11` records the final UTC refresh, baseline, Xcode 26.6 build `17F113`, Swift driver/compiler identifiers, Swift 5 language mode, CocoaPods 1.16.2, and OpenSpec 1.2.0. The recorded tool versions match the review environment.
- `openspec/changes/sdk-public-connect/evidence/validation-gates.md:7-20` records exact focused commands, the 405-test pre-final strict run, the final 406-test package run after the lock-local patch, both production TLS gates, and final CocoaPods validation.
- `openspec/changes/sdk-public-connect/evidence/logs/final-package-summary.log` records command, working directory, final-remediated environment, exit status zero, API/TLS/lease gates, 406 iOS tests with 402 passed, 4 skipped, 0 failed, 196 Core tests, and both production TLS tests passing 1/1.
- `openspec/changes/sdk-public-connect/evidence/logs/final-podspec-summary.log` records command, working directory, final-remediated environment, exit status zero, CocoaPods 1.16.2, the expected placeholder warning, and successful validation.
- `shasum -a 256 -c openspec/changes/sdk-public-connect/evidence/logs/SHA256SUMS` reports both preserved summaries as `OK`.

## Final Security Verification

- Terminal-wait registration and execution failures retain the exact process lease in the permanent fail-closed vault. The isolated macOS child test uses the real registry handle and proves a second claim remains contended after ordinary owners are dropped.
- Ordinary terminal evidence releases through the one-shot public wrapper and the lock-protected production handle exactly once. Claim-exit, release-enter, release-exit, repeated release, stale release, public detachment, shutdown, and post-terminal reacquisition regimes have explicit tests or audits matching the specification.
- The shared transition gate now captures cancellation-delivery state in a lock-local immutable value before unlocking. The final focused and aggregate gates compile and exercise the remediated synchronization path.
- Pairing ownership is one-shot at both the public orchestration and admission boundaries. Tests prove the transfer becomes empty after its synchronous take and the admission actor no longer retains pairing ownership at the first discovery suspension. No connected, terminal, channel, Keychain, Event, error, or callback owner stores pairing data.
- Installation identity access uses the exact seven-key read and six-key add dictionaries, the data-protection Keychain, authentication-UI skip, `WhenUnlockedThisDeviceOnly`, canonical lowercase RFC 4122 V4 validation, exactly 16 secure random bytes, and at most one duplicate reread. There is no update, delete, retry, prompt, logging, reflection, or OSStatus-forwarding path.
- Public errors remain exhaustive, fixed, and content-safe. They expose no pairing code, Bonjour name or TXT data, endpoint, interface, address, certificate, installation identifier, host metadata, Event, Security query, OSStatus, object identity, or arbitrary underlying description.
- The installation ID is accurately documented as a device-local correlation identifier rather than a secret or credential. Optional host metadata is bounded, actual-String-only, and sent inside the admitted TLS channel.
- Supported transport remains ordered TCP inside mandatory TLS 1.3 with `nearwire/1` ALPN and no plaintext downgrade. Documentation accurately explains connection-local leaf anchoring, lack of pre-established Viewer authentication, active local impersonation risk, and passive-observer protection.

## Final Performance and Resource Verification

- The maximum V1 Event record is derived in constant space from the validated 262,144-byte deterministic-content limit plus an exact direction-valid non-content wrapper. Production-codec equality, adversarial content, seeded JSON trees, exact boundary, and one-byte-under tests support the calculation.
- Frame payload, single-send, pending-send including two maximum Control frames, decoder, active incoming retention, and active-turn accounting use only `max(reviewedDefault, exactRequiredValue)` and remain within existing hard maxima.
- Changing `buffer.maximumEventBytes` affects only bounded active-turn accounting and does not widen the symmetric peer Event maximum, decoder, or transport network capacity.
- Receive chunks, ingress callbacks, frame decoding, batch counts, active incoming queues, stream buffers, transport mailbox count/bytes, per-turn service units/bytes, deferred policy transactions, deadlines, and scheduled work remain independently bounded and are cleared at terminal ownership transitions.
- Connect computes only fixed-size wrapper data and checked arithmetic; it does not allocate or encode a synthetic maximum content payload.

## Final Packaging and Documentation Verification

- SwiftPM links Apple's `Security.framework` only on the `NearWire` SDK target. CocoaPods links the same framework only on the SDK subspec. No third-party runtime dependency, entitlement, privacy resource, script hook, or supported Security/Network/internal orchestration type is added.
- The same public consumer fixture compiles in Swift 5 language mode for iOS 16 through both distribution paths, while boundary gates reject implementation, lease, wire, raw-channel, and plaintext-transport access.
- Public API, discovery, lease, session admission, active pump, transport security, distribution, roadmap, and README documentation consistently describe explicit one-shot connect, device-local identity, public pairing semantics, mandatory-but-unauthenticated TLS, exact states/errors, no delivery acknowledgement, and deferred disconnect/reconnection/background policy.
- Tasks 2.1 through 4.5 are backed by the final evidence set. Tasks 4.6 and 4.7 appropriately remain for zero-finding review completion and the final spec-to-evidence/archive gate.

## Conclusion

This security/performance/documentation review dimension is clean. The change is ready to proceed to the combined zero-finding review record and final spec-to-evidence/archive workflow.

