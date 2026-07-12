# Implementation Review Round 4: Security, Performance, and Documentation

## Scope and Verdict

This fresh review re-read the active `viewer-application-foundation` proposal, design, capability specifications, tasks, current Viewer and changed Core source, tests, Xcode project, resources, operator documentation, validation evidence, requirement-to-evidence audit, the Round 3 security/performance/documentation report, and `evidence/implementation-round3-remediation.md`. No production, specification, task, test, documentation, or evidence artifact was modified; this report is the only added file.

The combined 32-connection-owner bound is now closed under both cancellation waves and placeholder-handoff waves. The maintained project and documentation also replace ad-hoc persistence claims with a coherent stable Apple Development or Developer ID signing contract. However, the conditional update-boundary probe is not yet a complete or reproducible packaging gate: it cannot establish that two distinct maintained builds used the intended signer, and its unrelated-signer phase does not attempt or prove the required use, reset, and deletion denials. This is an implementation/evidence gap independent of the current host's lack of a signing identity.

**Unresolved actionable finding count: 1 (1 Medium).**

**Round 4 approval is withheld.**

## Round 3 Finding Recheck

| Round 3 finding | Round 4 result |
| --- | --- |
| `NW-SPD3-001`: ad-hoc signing could not establish persistent login-Keychain access across updates | **Partially resolved; still open.** Debug and Release now default to automatic `Apple Development` signing, while the design, specification, README, and operator documentation require one stable Apple Development signer for internal updates or Developer ID for distributed updates and limit ad-hoc output to tests and structural inspection. That contract is sound. The conditional cross-build probe remains incomplete; see `NW-SPD4-001`. Separately, this host has zero valid code-signing identities, so even a corrected gate will still require external stable-signer execution evidence before the requirement can be marked proven. |
| `NW-SPD3-002`: cleanup and placeholder ownership escaped the 32-slot hard cap | **Resolved.** Each reservation is captured by its per-attempt cleanup owner and released only after claim completion, connection-core cleanup, and all direct late-channel cleanup complete (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:456-531` and `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:682-771`). Cancellation no longer releases a slot in `finish`, and successful handoff retains it until the same core is cancelled by the placeholder owner (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:909-927`). The gated cancellation and automatic-placeholder waves each occupy all 32 slots, reject the 33rd wrapper before claim, drain exactly once, and finish with zero occupied slots (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1619-1686`). The focused test also passed 20 fresh iterations. Documentation and the active specification now describe the combined owner bound. |

## Finding

### NW-SPD4-001 — Medium — The conditional stable-signer probe cannot prove the complete update-boundary contract

**Evidence**

- The stable-update scenario requires a newer maintained build with the same supported signer to reuse and use the identity, and requires an unrelated signer to be unable to read, use, reset, or delete the records (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:40-44`). Round 3 required the integration gate to exercise independently built products and prove unrelated-signer access and deletion denial (`openspec/changes/viewer-application-foundation/reviews/implementation-round3-security-performance-documentation.md:40-47`).
- `testStableSignerUpdateBoundaryProbe` chooses its phase only from the presence of fixed files under `/tmp/nearwire-viewer-stable-signer-probe` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:522-549`). The first invocation writes `expected.json`; every later non-denial invocation is treated as build B. The test records no executable hash, product version, code-signing designated requirement, Team ID, certificate identity, or phase manifest. Running the same test product twice can therefore satisfy its A/B branches without proving an update boundary or the selected supported signer.
- The unrelated-signer branch only calls `XCTAssertThrowsError(try store.loadOrCreate())` and immediately returns (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:542-547`). It accepts any error and never attempts a private-key use, `resetTLSIdentity`, `resetAllIdentity`, or exact record deletion. A generic setup or identity-validation error could pass this branch, while the specification's use/reset/delete denial remains untested.
- The probe uses isolated test selectors rather than the maintained production selectors (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:540`), while the ordinary same-binary tests already cover isolated selectors. This can be a safe choice only if the packaging gate explicitly documents that substitution and proves that every security-relevant Keychain attribute and access-control path matches production; no such gate contract is recorded.
- No script or operator runbook defines the exact A, unrelated-signer, and B commands; secure state-directory creation and cleanup; expected signer selection; required product distinction; signature inspection; phase ordering; failure handling; or evidence capture. `Documentation/Viewer-Foundation.md:32` states only that the gate must run, and `evidence/implementation-validation.md:54` states the intended order without supplying an executable procedure.
- The current ordinary suite correctly skips this probe when its marker is absent, and the audit correctly leaves stable-signer evidence pending. The current host reports `0 valid identities found`; consequently no cross-build Keychain ACL result was produced. That external limitation does not account for the probe omissions above.

**Impact**

The present probe can produce a passing result from two executions of one product or from an unrelated-signer phase that failed for an unrelated reason. It cannot demonstrate the destructive-operation boundary that protects persistent Viewer identity records. The result would therefore be insufficient to close `NW-SPD3-001`, satisfy the stable-update scenario, mark tasks 5.1/5.4 complete, or archive the change, even if a signing identity became available.

**Required action**

1. Give the gate explicit A, unrelated-signer, and B phases and a securely created per-run state directory instead of inferring phase solely from fixed marker files.
2. Capture and validate enough product/signature metadata to prove that A and B are distinct maintained builds and use the intended same stable signer, while the denial phase uses a genuinely unrelated signer. Save `codesign` inspection output with the test evidence.
3. In the unrelated-signer phase, explicitly attempt non-interactive exact reads, private-key use, TLS reset, full reset, and deletion; require the expected access-denial class for each safe operation, then have build B prove that all original records remained intact before exercising the authorized reset paths.
4. Either exercise production selectors in an isolated validation account/keychain or document and mechanically verify that the probe selectors preserve every security-relevant production query and access-control attribute.
5. Add an English operator command sequence or runner that controls signer selection, products, phase state, cleanup, and evidence capture. Then run it on a host with the required stable and unrelated identities and save the exact result under this change's `evidence` directory.

## Verified Security, Performance, Privacy, and Documentation Boundaries

- The connection-owner reservation is acquired before wrapper claim and is retained through claim-in-progress, policy cancellation, late direct-channel cleanup, asynchronous core cancellation, and placeholder ownership. No later wave can create a 33rd retained per-connection owner.
- The ten-second monotonic deadline still selects handoff or cancellation without pretending that delayed cleanup has finished. Delayed cleanup consumes the same finite reservation.
- Synchronous listener ingress rejection and synchronous connection-core decoding preserve backpressure before MainActor work and avoid a second unbounded pre-Hello queue.
- The stable signing policy is now truthful: maintained internal builds require one team-selected Apple Development signer, Developer ID is the distribution alternative, and ad-hoc output is not persistence evidence.
- Exact non-interactive Keychain reads and deletes, strict owned-certificate validation, nonexportable P-256 key validation, TLS-only reset, full reset, and foreign-item preservation remain intact in production source and same-binary tests.
- TLS 1.3, NearWire ALPN, connection-local certificate validation, App Sandbox, and incoming network-server-only entitlements remain mandatory. No plaintext or identity-free fallback was introduced.
- UI and documentation continue to state that transport is encrypted but Viewer identity is not authenticated, and they describe pairing code and `vid` as nearby-visible identifiers rather than passwords or secrets.
- The privacy manifest, local-network/Bonjour metadata, fixed safe recovery text, current-scope boundary, and lack of third-party Viewer runtime dependencies remain consistent with the active artifacts.

## Fresh Validation Performed

All commands were run from the repository root on 2026-07-12.

1. `xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-viewer-round4-spd-dd -clonedSourcePackagesDirPath /tmp/nearwire-viewer-round4-spd-spm test CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`
   - Result: exit 0. The result bundle contains 55 tests: 54 passed and the conditional stable-signer packaging probe was the sole skip.
2. `xcodebuild ... test-without-building ... -only-testing:NearWireViewerTests/ViewerFoundationTests/testCombinedAdmissionBoundIncludesCancellingAndPlaceholderOwnedConnections -test-iterations 20`
   - Result: exit 0; all 20 iterations passed.
3. `security find-identity -v -p codesigning`
   - Result: exit 0; `0 valid identities found`. No stable-signer phase was represented as executed.
4. `openspec validate viewer-application-foundation --strict`
   - Result: the change is valid. The later non-gating PostHog telemetry flush reported unavailable network access.
5. `./Scripts/verify-english.sh`, `./Scripts/verify-structure.sh`, and `./Scripts/verify-boundaries.sh`
   - Result: exit 0 for all gates.
6. `git diff --check`
   - Result: exit 0.

## Completion Gate

The combined-cap remediation is approved. The stable automatic signing contract is also acceptable as an implementation choice, but its packaging probe must be completed as specified above and then executed with real stable and unrelated signing identities. Until both the implementation gap and the distinct external execution-evidence gate are closed, Round 4 security/performance/documentation approval remains withheld and the active change must not be archived.
