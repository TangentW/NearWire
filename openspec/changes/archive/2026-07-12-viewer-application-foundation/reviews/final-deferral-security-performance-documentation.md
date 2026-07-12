# Final Deferral Review: Security, Performance, and Documentation

## Scope and Verdict

This lightweight artifact-only review examined the current `viewer-application-foundation` signer-evidence deferral. It re-read the active stable-signing requirements, design, task state, operator procedure, implementation and remediation evidence, requirement-to-evidence audit, repository workflow wording, implementation roadmap, and final zero-finding review status. No production source, test source, specification, task, documentation, or evidence artifact was modified; this report is the only added file. No build or long-running test was executed.

The deferral is truthful and does not weaken the security model or substitute ad-hoc output for supported-signer evidence. The executable gate remains intact, the normative trust boundary remains unchanged, and `release-hardening` is explicitly prohibited from completing until the stable A / unrelated signer / stable B sequence runs successfully with two valid unrelated identities and its results are saved.

**Exact unresolved actionable finding count: 0.**

**Approved.** The `viewer-application-foundation` change may archive with the environment-dependent signer execution explicitly deferred, provided the archive retains the current pending-evidence statements and does not claim that cross-update Keychain behavior has already been proven.

## Security Requirement Preservation

No trust or security requirement was relaxed by the deferral.

- Maintained internal builds still require one stable Apple Development signing identity across updates; Developer ID remains the supported distribution alternative. An ad-hoc build is still explicitly excluded as proof of cross-update login-Keychain persistence (`specs/viewer-application-foundation/spec.md:27-44`, `design.md:29`, and `Documentation/Viewer-Foundation.md:11`).
- The stable-update scenario still requires a newer supported-signer build to non-interactively reuse the installation and TLS identities and perform real private-key signing. An unrelated signer must remain unable to read, use, reset, or delete those records (`specs/viewer-application-foundation/spec.md:40-44`).
- Exact interaction-disabled Keychain reads, key use, both reset scopes, and exact record deletion remain part of the deny phase. Stable B must prove the original installation ID, certificate, and private key remain intact before authorized resets (`Documentation/Viewer-Foundation.md:15-34`).
- The three products must still have distinct signed bundle versions, Code Directory hashes, host-app paths, and operator build identifiers. Stable A and B must share the complete supported-signer fingerprint; deny must have an unrelated designated requirement (`evidence/implementation-round6-remediation.md:7-13`).
- TLS remains mandatory and the Viewer remains explicitly unauthenticated in V1. The deferral adds no plaintext fallback, trust-all behavior, arbitrary-app Keychain ACL, or weakened certificate validation.

The deferred item is execution evidence on a suitably configured host, not implementation of the gate or definition of the security contract.

## Ad-Hoc Evidence Boundary

The artifacts consistently refuse to treat ad-hoc results as supported-signer evidence.

- Viewer documentation reserves ad-hoc signing for isolated tests and structural inspection because its changing code requirement cannot demonstrate non-interactive Keychain access across rebuilds (`Viewer/README.md:9` and `Documentation/Viewer-Foundation.md:11`).
- The ordinary Viewer suite records one explicit conditional signer-gate skip. It does not convert that skip into success or cross-update evidence (`evidence/implementation-validation.md:47-54`).
- The saved ad-hoc Release result proves buildability, final plist/resource packaging, entitlements, privacy declarations, and current Designated Requirement validity only. It is not cited as proof that a stable update can reuse the file-based Keychain identity.
- The fallback investigation did not install a local trust root, alter the default Keychain search list, or accept disposable self-signed identities. The temporary certificates were not valid signing identities, `codesign` rejected them, and all temporary Keychains and private material were removed (`evidence/implementation-round6-remediation.md:19-21`).

No artifact substitutes an ad-hoc signature, locally trusted test root, same-binary login-Keychain test, or static project setting for the required three-product evidence.

## Mandatory Release-Hardening Gate

The deferral has a concrete, mandatory destination rather than becoming an unowned future note.

- `Documentation/Implementation-Roadmap.md:101-105` assigns the final-system signing and distribution readiness audit to `release-hardening` and states that it must execute the documented Viewer A / unrelated / B sequence with two valid unrelated signing identities.
- The same roadmap explicitly says `release-hardening` cannot complete while the cross-update Keychain evidence remains pending. This is a hard completion condition, not a recommendation.
- `evidence/requirement-to-evidence-audit.md:19` labels the identity implementation as implemented while explicitly deferring final release evidence. Its cross-cutting gate at line 35 again states that NearWire completion is prohibited until the supported-signer sequence passes.
- `evidence/implementation-validation.md:54` records the exact missing environmental capability, preserves the A / unrelated / marker / B procedure, and states that the result is neither inferred from ad-hoc output nor required to be misreported as part of this archive.
- `evidence/implementation-round6-remediation.md:19` records the user's explicit decision and keeps both the executable XCTest and operator recipe in the repository for the final gate.

Ownership, required identities, procedure, blocking effect, and evidence destination are all explicit. The deferral therefore does not create an ambiguous or optional security TODO.

## Archive Truthfulness

The current task and audit wording distinguish implementation completion from final-system evidence completion:

- Tasks 5.1 and 5.4 now require the conditional gate implementation and ordinary validation while explicitly preserving supported-signer execution as the mandatory deferred `release-hardening` gate.
- Task 6.3 remains unchecked until the requirement-to-evidence audit, archive verification, and isolated commit actually occur.
- The audit result is `Implemented; final release evidence deferred`, not `Proven`.
- The implementation validation records `0 valid identities found` and one conditional skip rather than claiming the A / unrelated / B sequence ran.
- Final reviews approve the implemented gate with zero unresolved implementation findings while continuing to identify the external signing-host evidence as outstanding.

Archiving this change is therefore truthful if the archive preserves those exact distinctions. The archive must not rewrite the identity row as fully proven, mark the deferred external execution as passed, omit the conditional skip, or describe the ad-hoc Release product as cross-update evidence.

The generic repository rule that a change archives after zero-finding implementation review remains satisfied. The more specific roadmap rule preserves the environment-dependent final-system evidence as a mandatory later gate before NearWire release completion.

## Performance and Documentation Recheck

The signer-evidence deferral does not affect runtime performance, connection-owner capacity, cleanup ordering, protocol behavior, or application resource use. The conditional probe remains absent from normal runtime behavior and normal builds carry only empty reserved Info.plist strings.

Documentation remains aligned across the Viewer operator guide, design, validation evidence, requirement audit, task plan, and implementation roadmap. The distinction among implementation evidence, ad-hoc packaging evidence, supported-signer integration evidence, and final release evidence is explicit and consistent.

## Findings

No actionable security, performance, privacy, workflow-ownership, or documentation finding was identified.

## Completion Condition

This review approves only the truthful deferral and archive representation. It does not approve or infer the missing cross-update behavior.

Before `release-hardening` or NearWire final release can complete, a configured signing host must:

1. run stable create A with a supported signing identity;
2. run deny with a valid identity having an unrelated designated requirement;
3. create the completion marker only after deny succeeds;
4. run a distinct stable verify B with the original supported signer;
5. save the exact signing inspection and XCTest results; and
6. update the final requirement audit from deferred to proven only after that evidence exists.

Until then, the deferred evidence remains open by design even though `viewer-application-foundation` may archive.
