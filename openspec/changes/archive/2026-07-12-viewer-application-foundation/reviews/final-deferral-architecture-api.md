# Final Signer-Evidence Deferral Review — Architecture and API

## Review Scope

This was a lightweight artifact-only review of the current `viewer-application-foundation` signer-evidence deferral. It inspected the active capability delta, task plan, requirement-to-evidence audit, implementation validation/remediation records, final implementation reviews, Viewer operator documentation, repository workflow rules, and implementation roadmap. No source, test, specification, task, evidence, or product document was modified; this report is the only added file. No long validation or test command was run.

## Deferral Audit

### Capability and executable gate remain intact

The stable-update behavior has not been removed or weakened. The capability still requires stable Apple Development or Developer ID signing, same-signer noninteractive identity reuse plus real private-key signing, and unrelated-signer read/use/reset/delete denial (`specs/viewer-application-foundation/spec.md:27-46`).

The deferral clause is narrow: this change must deliver the app-hosted A/unrelated/B XCTest and fail-fast operator recipe; only execution evidence may move when the implementation host has no valid identities; the gate remains mandatory; and the final NearWire completion audit must fail until it passes (`specs/viewer-application-foundation/spec.md:31`). The current operator document still contains the exact create, unrelated-deny, completion-marker, and verify sequence with distinct supported signers, signed build identities, and shared state (`Documentation/Viewer-Foundation.md:15-34`). The signed-host transport, Code Directory/product identity checks, post-denial marker, exact Keychain denial operations, and authorized final verification remain implemented and reviewed.

### Only environment-dependent execution moved

Tasks 3.1 and 5.1 still mark the stable-signer storage implementation and conditional executable gate as delivered. Task 5.4 accurately distinguishes completed ad-hoc build/test/packaging validation from the supported-signer execution that is now a mandatory deferred `release-hardening` gate. It does not mark the real A/unrelated/B run as completed (`tasks.md:14,26-29`).

The audit uses the precise result `Implemented; final release evidence deferred`, rather than `Proven`, for the identity requirement. It records that the conditional gate exists and is reproducible while attributing the remaining absence solely to the explicitly deferred supported-signer execution (`evidence/requirement-to-evidence-audit.md:18-19`). The validation record likewise states that the host has zero valid identities, does not infer success from ad-hoc output, and names the release-hardening deferral (`evidence/implementation-validation.md:47-62`).

The remediation record is also explicit that no trusted local root or ad-hoc substitute was accepted, that temporary fallback material was removed, and that the executable gate and recipe remain part of this change (`evidence/implementation-round6-remediation.md`). Thus the archive will not claim that cross-update Keychain behavior was observed on a supported signing host.

### Release-hardening remains a mandatory closure gate

The repository roadmap assigns signing and distribution readiness plus the final requirement-by-requirement audit to `release-hardening`. It separately states that release hardening cannot complete until the documented Viewer A/unrelated/B sequence runs with two valid unrelated identities (`Documentation/Implementation-Roadmap.md:101-105`). The capability's own deferral clause independently requires the final NearWire audit to fail while that evidence is pending. This duplicates the guard at both capability and program-plan levels, so archiving the foundation change does not make the obligation disappear.

The requirement-to-evidence audit repeats the same prohibition under cross-cutting gates: NearWire completion remains prohibited until the deferred final-system gate passes. No artifact describes the ordinary ad-hoc skip, automatic signing configuration, safe invalid-phase check, or final archive as equivalent evidence.

### Archive and next-change sequencing are safe

Task 6.3 remains unchecked and still requires completion of the audit, archive verification, and isolated commit before `viewer-multidevice-flow-control` begins. The repository README and roadmap retain the global rule that one change must be archived before the next enters apply (`tasks.md:33-35`; `README.md:64-66`; `Documentation/Implementation-Roadmap.md:107-115`). The deferral expands neither the current implementation scope nor authorization to begin the next change early.

After archive, the capability requirement—including the mandatory release-hardening clause—will become canonical specification state. The next Viewer change consumes the existing opaque handoff and extends the same connection core; it does not depend on pretending that external signing evidence already exists (`specs/viewer-application-foundation/spec.md:117-121`; `Documentation/Viewer-Foundation.md:97-99`). Multi-device work can therefore proceed after the normal archive gate without altering identity selectors, signing policy, or the deferred executable test.

The older Round 6 completion paragraphs that required the foundation change itself to remain active accurately described the policy before the user's explicit deferral decision. The later capability amendment, task wording, audit result, roadmap gate, remediation record, and this final independent review make that policy change explicit rather than silently rewriting historical review reports.

## Findings

No actionable architecture or API finding was identified.

The deferral is an evidence-scheduling decision, not a capability or implementation downgrade. It preserves the normative behavior, executable verification mechanism, honest pending-evidence status, final release prohibition, and archive-before-next-change sequence.

## Verdict

**Approved.** `viewer-application-foundation` may complete its normal audit/archive/commit step with the supported-signer execution explicitly deferred. `viewer-multidevice-flow-control` may begin only after that archive step completes. The repository's final `release-hardening` change remains blocked until the documented A/unrelated/B gate executes successfully and exact evidence is saved.

**Exact unresolved actionable finding count: 0.**
