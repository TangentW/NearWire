# Final Signer-Evidence Deferral Correctness Review

Date: 2026-07-13

## Scope

Performed a lightweight artifact-only review of the current `viewer-application-foundation` signer-evidence deferral. Reviewed the active task completion wording, capability requirement, implementation validation and remediation records, requirement-to-evidence audit, Viewer operator documentation, and the repository implementation roadmap's `release-hardening` gate. No production source, test source, specification, task, documentation, or evidence artifact was modified; this report is the only added file. No long validation command was run.

## Findings

No unresolved correctness or evidence finding was identified.

## Task Completion Is Truthful

Task 5.1 is correctly checked as complete because it requires adding the deterministic and integration test coverage, including the **conditional** stable-signer update-reuse and unrelated-signer gate. The app-hosted create/deny/verify XCTest and fail-fast operator recipe are implemented, locally validated for configuration forwarding and fail-closed behavior, and preserved in the repository. The task does not state that this implementation host must fabricate two signing identities or treat the conditional skip as a successful cross-signer execution (`tasks.md:26`).

Task 5.4 is also correctly checked as complete under its current explicit scope. It requires the Viewer and repository's available ad-hoc-test-sign build, test, packaging, metadata, and validation gates, all of which have saved results. Its final sentence expressly preserves supported-signer A/unrelated/B execution as a mandatory deferred `release-hardening` gate when the current host has no valid identities (`tasks.md:29`). The checkbox therefore represents completion of this change's implemented and locally executable validation work, not completion of the deferred release evidence.

This interpretation is reinforced by the active capability requirement. It requires this change to deliver the executable app-hosted gate and recipe, permits execution evidence to move to final `release-hardening` when the implementation host has no valid signing identities, and still makes the gate mandatory (`specs/viewer-application-foundation/spec.md:31`). No checked task silently weakens that normative boundary.

## Requirement Audit Does Not Overclaim

The identity row in `evidence/requirement-to-evidence-audit.md` distinguishes implementation from execution:

- it records same-binary and injected Keychain lifecycle evidence as passing;
- it describes the implemented three-product conditional gate and its exact coverage;
- it says execution on a configured signing host was explicitly deferred; and
- its result is `Implemented; final release evidence deferred`, not `Proven`.

The cross-cutting section separately reports the ordinary Viewer result as 55 passed, one explicit stable-signer skip, and zero failed. It then names the deferred final-system gate and states that NearWire completion remains prohibited until it passes. The audit therefore neither counts the conditional skip as success nor claims that same-signer reuse and unrelated-signer denial ran on this host.

`evidence/implementation-validation.md` is equally explicit: the current host reports zero valid identities, execution is not inferred from ad-hoc output, and the A/unrelated/B sequence remains mandatory final verification. `evidence/implementation-round6-remediation.md` records the same external limitation and states that the implementation archive does not claim the sequence ran.

## Final Release Gate Is Explicit and Mandatory

The deferral has two independent durable gates:

1. The active Viewer capability specification says the final NearWire completion audit **shall fail** until the supported-signer sequence passes (`specs/viewer-application-foundation/spec.md:31`).
2. The repository roadmap's `release-hardening` section says the final release gate must execute the documented Viewer A/unrelated/B XCTest with two valid unrelated identities, and that release hardening cannot complete while the evidence remains pending (`Documentation/Implementation-Roadmap.md:101-105`).

The requirement audit repeats the same prohibition under `Deferred final-system gate`, while `Documentation/Viewer-Foundation.md` retains the exact fail-fast command sequence needed to discharge it. These references identify the required test, required signer topology, evidence destination, and blocking completion condition. The gate is therefore not a soft roadmap note or an unowned TODO.

## Verdict

**Approved.** Tasks 5.1 and 5.4 truthfully represent implemented test and local-validation completion; the requirement audit accurately labels cross-signer execution as deferred; and final `release-hardening` is normatively prohibited from completion until the supported-signer evidence passes.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**
