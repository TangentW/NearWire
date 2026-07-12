# Implementation Review Round 5: Security, Performance, and Documentation

## Scope and Verdict

This fresh review re-read the complete current `viewer-application-foundation` worktree after Round 4 remediation: active proposal, design, capability specifications, tasks, Viewer and changed Core production source, tests, Xcode project, resources, documentation, validation evidence, requirement-to-evidence audit, all three Round 4 implementation reports, and `evidence/implementation-round4-remediation.md`. No production, specification, task, test, documentation, or evidence artifact was modified; this report is the only added file.

The connection-owner lifetime and finite-resource remediation is now coherent and independently passing. The stable-signer probe also materially improves the prior gate: it uses explicit phases and an explicit shared state root, fingerprints the actual app-host process with Security.framework, rejects a deny product with the same build label, test-product path, composite signer fingerprint, or designated requirement, exercises exact non-interactive read/use/reset/delete operations, and has a reproducible three-command operator recipe without adding a script.

One gate-integrity defect remains. The deny phase publishes no durable completion record, and verify requires only the create record. The documented three-phase gate can therefore report successful create and verify executions while the unrelated-signer phase was skipped entirely. The claimed distinct update build is also represented only by an operator-provided environment label and a test-bundle path, not by signed host-build metadata. This is an implementation/evidence defect, separate from the current host's lack of signing identities.

**Exact unresolved actionable finding count: 1 (1 Medium).**

**Round 5 security/performance/documentation approval is withheld.**

## Round 4 Finding Recheck

| Round 4 concern | Round 5 result |
| --- | --- |
| Stable-signer probe lacked explicit build/signing metadata and exact unrelated-signer operation coverage | **Substantially remediated, but not closed.** `SecCodeCopySelf` fingerprints the actual app-host process by Team ID, leaf-certificate hash, and designated requirement. Deny rejects reuse of the create build label and test-product path and now specifically requires a different designated requirement. It calls production load and both reset APIs, then independently attempts exact non-interactive generic-password reads, private-key lookup/signing, and generic-password/private-key/certificate deletes. Verify rechecks the original installation ID, certificate hash, and private-key use before authorized resets. The missing deny-completion and host-build identity binding remain as `NW-SPD5-001`. |
| Handoff shutdown could complete before reservation release, and same-runtime recycling was unproved | **Resolved.** `ViewerAdmissionHandle` retains the attempt cleanup owner and `cancelAndWait()` waits for both core cleanup and cleanup publication (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:144-183`). `ViewerAdmissionAttemptCleanup.publishCompletion()` runs the exact budget-release/registry-removal callback before completing cleanup waiters (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:458-559`), and handed-off attempts remain in the registry until that callback (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:731-745` and `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:946-956`). Stop therefore joins slot release as well as channel ownership. The same-manager test drains eight of 32 handoffs, observes 24 owners, refills exactly eight, rejects overflow, and drains once to zero (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1911-1980`). The combined-bound, recycling, and accepted-handoff receipt tests passed 20 fresh iterations. |
| Burst admission test observed cancellation notification instead of cleanup completion | **Resolved.** The test now awaits the stop receipt before asserting zero occupied owners (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1599-1634`). The fresh complete suite passed. |
| Specification retained wording from the superseded early slot-release model | **Resolved.** The normative contract now retains claim-in-progress, cancelling, handed-off, and late-channel cleanup in one registry and requires exact slot release before cleanup completion publication (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:111-117`). Operator documentation matches that ordering. |

## Finding

### NW-SPD5-001 — Medium — The update gate does not require a completed deny phase or identify an actually different host build

**Evidence**

- The create record stores the original installation ID, certificate hash/reference, signer fingerprint, caller-supplied build ID, and `Bundle(for: Self.self).bundleURL.path` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:546-569` and `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:2549-2557`). It has no phase state, deny-product fingerprint, deny result, or transition nonce.
- Deny correctly validates a different build label, test-bundle path, composite signer fingerprint, and designated requirement before attempting destructive operations (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:571-585`). It does not atomically write any successful-denial receipt after all assertions pass.
- Verify reads only `expected.json`, compares itself only with create, and immediately proceeds to authorized identity reload, TLS reset, full reset, and fixture-directory removal (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:587-610`). A create invocation followed directly by verify satisfies every executable guard and deletes the fixture without ever running deny. The command sequence in `Documentation/Viewer-Foundation.md:19-29` asks the operator to run deny but cannot make the final test result prove that it happened.
- The build ID is arbitrary environment text. The recorded product path comes from the XCTest bundle, while the signer fingerprint comes from the actual host via `SecCodeCopySelf`. Neither the host executable hash/CDHash nor a signed build/version value is recorded. Rebuilding unchanged source into another DerivedData directory and supplying another build label satisfies the A/B distinction, even though the normative scenario calls for a newer maintained Viewer build (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:40-44`).
- The new explicit state root is preferable to per-process temporary-directory inference, and only create creates the token directory while deny reads it and verify removes it. However, state-root continuity alone does not prove the missing deny transition.
- This host still reports `0 valid identities found`. Consequently the ordinary suite correctly skips the conditional probe, and the requirement-to-evidence audit correctly leaves external execution pending. The missing identities explain why the real ACL behavior has not run; they do not explain the state-machine defect above.

**Impact**

Saved command exits can show create and verify succeeding while the security-critical unrelated-signer phase was omitted. They can also show two differently labelled/path-located copies of the same host build rather than an update. Such evidence would be insufficient to prove the stable-update scenario, close the original persistent-Keychain finding, mark tasks 5.1/5.4 complete, or archive the change.

**Required action**

1. After every deny assertion succeeds, atomically persist a deny receipt containing the token, create-record digest, deny build identity, actual deny signer fingerprint, and a completed-phase marker.
2. Make verify require and validate that receipt before it may load or reset the identity or remove probe state. Reject missing, repeated, reordered, mismatched, or tampered transitions.
3. Bind A/B distinction to the actual host product, not only environment labels and the XCTest bundle path. Record the main host path plus signed build/version and executable/CDHash or another mechanically derived host-build digest; require A and B to differ in build identity while retaining the same supported signer fingerprint.
4. Update the existing no-script operator recipe and evidence description to name the enforced transition record and actual host-build check. Then run the three phases with two valid unrelated identities and save exact signature inspection and XCTest results.

## Verified Security, Performance, Privacy, and Documentation Boundaries

- Deny cannot reach reset/delete operations when it reuses create's build label or test-product path, when its composite signer equals create, or when its designated requirement equals create. These guards execute before the destructive branch.
- The signer fingerprint comes from `SecCodeCopySelf`, `SecCodeCopyStaticCode`, `SecCodeCopyDesignatedRequirement`, and `SecCodeCopySigningInformation`; it does not trust `IDENTITY_*` or `TEAM_*` environment values as runtime proof.
- Exact denial operations use an interaction-disabled `LAContext` and the same isolated production-mode service, accounts, key tag/class/type, synchronization, file-based-Keychain flag, and certificate persistent reference as the store path. The final stable branch checks original installation identity, certificate, and real private-key use before supported reset operations.
- The documented state root is explicit and shared across products. Create alone creates its token directory, deny only reads it, and verify removes it after authorized full reset. No new validation script or runtime dependency was introduced.
- The runtime-wide budget remains exactly 32 across pre-claim, pre-Hello, approval, asynchronous cancellation, late-channel cleanup, placeholder handoff, and partial drain/refill. Cleanup completion and stop receipt cannot publish before the exact slot is released.
- Synchronous ingress and connection-core decoding retain bounded backpressure; pending UI state remains latest-only, fair across MainActor turns, and generation-scoped.
- Stable Apple Development or Developer ID signing remains the maintained persistence contract. Ad-hoc products remain limited to ordinary tests and structural packaging inspection and are not represented as cross-update evidence.
- TLS 1.3, NearWire ALPN, connection-local certificate validation, sandbox server-only entitlement, fixed safe diagnostics, truthful unauthenticated-Viewer wording, Bonjour-visible identifier disclosure, and privacy-manifest claims remain consistent across source, spec, UI, and documentation.
- Active Event transfer, multi-device session behavior, persistence/search/export, controls, and performance dashboards remain outside this foundation change and are not claimed as implemented.

## Fresh Validation Performed

All commands were run from the repository root on 2026-07-12.

1. Current-source complete Viewer suite:
   `xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-viewer-round5-spd-current -clonedSourcePackagesDirPath /tmp/nearwire-viewer-round5-spd-current-spm CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`
   - Result: exit 0. The fresh result bundle reports 56 tests: 55 passed, the conditional stable-signer test was the sole skip, and the overall action succeeded.
2. Combined owner, same-runtime recycling, and accepted-handoff receipt selection with `-test-iterations 20`:
   - Result: exit 0; all 20 iterations passed.
3. `security find-identity -v -p codesigning`
   - Result: exit 0 with `0 valid identities found`. No conditional signer phase was claimed as executed.
4. `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`
   - Result: exit 0; the change is valid.
5. `./Scripts/verify-english.sh`
   - Result: exit 0.
6. `git diff --check`
   - Result: exit 0.

## Completion Gate

The finite-owner/resource remediation, cleanup receipt ordering, stable-signing contract, exact unrelated-signer operation coverage, documentation, and ordinary regression state are approved. The three-phase packaging gate itself is not yet tamper-evident or self-proving because verify does not require deny completion and does not identify an actually different host build. After that implementation defect is fixed, the separate external gate still requires execution with two valid unrelated signing identities. Until both conditions are satisfied, Round 5 security/performance/documentation approval remains withheld and the change must not be archived.
