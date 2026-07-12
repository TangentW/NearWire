# Implementation Correctness and Testing Review — Round 4

Date: 2026-07-12

## Scope

Independently re-read the current `viewer-application-foundation` proposal, design, capability specifications, tasks, all implementation-review reports through Round 3, `evidence/implementation-round3-remediation.md`, validation and requirement-audit evidence, affected Core and Viewer production source, the manual Viewer project, Viewer and changed Core/SDK tests, resources, and product documentation. This review retraced both Round 3 findings and freshly audited the combined connection-owner budget, exact reservation release, claim-in-progress cleanup, handoff shutdown, stable-signing contract, and conditional update-boundary probe. No production, specification, task, test, documentation, or evidence artifact was modified; this report is the only added file.

## Round 3 Finding Disposition

| Round 3 finding | Round 4 disposition |
| --- | --- |
| Stable login-Keychain access was incorrectly claimed for ad-hoc updates | **Partially remediated, not closed.** The project now defaults to automatic Apple Development signing, the active contract correctly requires a stable supported signer, ad-hoc output is no longer claimed as cross-update evidence, and the same-signer branch of the conditional probe meaningfully checks identity reuse, real private-key signing, TLS reset, and full reset. The probe remains externally unexecuted because this host reports no valid code-signing identity, and its unrelated-signer phase does not test the required reset/deletion denial; see Finding 1. |
| Cleanup and placeholder ownership escaped the 32-slot admission bound | **Resource cap resolved, completion proof incomplete.** Reservations now remain occupied through cancellation and placeholder cleanup, and the 33rd wrapper is rejected before claim while 32 cleanup operations are gated. However, the accepted-handoff path removes the attempt from the cleanup registry before the independent reservation-release callback is known to have run, and the claimed multi-wave test is two isolated single-wave cases rather than recycling capacity in one runtime; see Finding 2. |

## Findings

### 1. P1 / High — The stable-signer requirement still lacks executable evidence, and the conditional unrelated-signer phase does not test reset or deletion denial

**Confidence: 10/10**

The corrected normative contract requires a same-signer update to reuse both identities and perform real signing, while an unrelated signer cannot read, use, reset, or delete the records (`specs/viewer-application-foundation/spec.md:29,40-44`). The checked-in project and documentation now express the right supported deployment model: automatic Apple Development signing for maintained internal builds, Developer ID as the distribution alternative, and ad-hoc signing only for isolated tests or structural inspection.

The conditional test is only partially sufficient (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:522-582`). Its first and final same-signer phases create and reload isolated production-mode login-Keychain records, compare the installation identifier and certificate hash, exercise a real `SecKeyCreateSignature`, verify TLS reset preserves the installation identifier while rotating the certificate, and invoke full reset. Those are technically meaningful update-boundary operations when the test is actually hosted by two independently built products with the same stable designated requirement.

The unrelated-signer branch, however, contains only `XCTAssertThrowsError(try store.loadOrCreate())` and returns (`ViewerFoundationTests.swift:542-547`). It never invokes `resetTLSIdentity()` or `resetAllIdentity()`, never attempts the exact deletion selectors, and therefore cannot prove the explicit reset/delete denial in the requirement. A later same-signer reload would show that this particular load attempt did not mutate the records, but it would still not exercise the destructive operations that are required to be denied. The repository also contains no executable orchestration that verifies build A and build B have the intended same stable designated requirement while the denial build has an unrelated requirement; the evidence only describes the manual phase order.

Fresh host inspection reports `0 valid identities found`, and the complete Viewer run therefore skips this probe exactly once. The requirement-to-evidence audit correctly marks stable-signer evidence pending and tasks 5.1 and 5.4 remain unchecked. The original High-risk cross-update contract is consequently not yet proven and cannot be closed by reviewing an unexecuted conditional branch.

**Required resolution:** extend the denial phase to attempt noninteractive load/use, TLS reset, full reset, and exact record deletion through the production store boundary, and prove each is denied. Make the subsequent same-signer phase verify the original records are still intact before exercising the supported reset scopes. Provide a reproducible gate that inspects the designated requirements of independently built A/B and unrelated products, rejects an invalid signer arrangement, executes all phases with one unique cleanup token, and records exact results. Run that gate with an actual supported stable identity and an unrelated identity before marking the requirement and tasks complete.

### 2. P2 / Medium — Accepted-handoff receipt completion is not ordered after reservation release, and current coverage is not a same-runtime multi-wave release proof

**Confidence: 9/10**

The combined cap itself is materially improved. The attempt completion callback is now the only ordinary path that releases its `ViewerAdmissionBudget.Reservation` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:697-723`), and `finish` no longer releases at the handoff-or-cancel decision (`ViewerAdmission.swift:909-927`). Claim-in-progress, late-channel, cancellation, and placeholder cleanup therefore retain one of the 32 slots, and the 33rd arrival is conservatively rejected.

The accepted-handoff path nevertheless has no happens-before edge from stop-receipt completion to that release. After `handoffOwner.transfer` succeeds, the manager starts an unstructured attempt-cleanup task waiting for the core, then immediately removes that attempt from `ViewerAdmissionCleanupRegistry` via `transferOwnership` (`ViewerAdmission.swift:919-925`). The handoff owner's shutdown task also waits for the same core. When core cleanup completes, both waiters become runnable: the handoff owner may remove its active handle and satisfy the stop receipt before the independent attempt-cleanup task executes `finishCoreCleanup()` and its `onComplete` callback releases the reservation (`ViewerAdmission.swift:477-530,539-598,806-829`). Swift task scheduling provides no ordering between those resumed tasks.

This is conservative for admission capacity during a running runtime, but it means the documented cleanup receipt can report completion while `occupiedCount` is transiently nonzero and while the slot-release bookkeeping it is expected to cover is still outstanding. Existing tests commonly observe zero after awaiting the receipt, but they rely on favorable scheduling rather than a deterministic ownership edge.

`testCombinedAdmissionBoundIncludesCancellingAndPlaceholderOwnedConnections` validates two important extreme cases and passed ten repeated runs in this review (`ViewerFoundationTests.swift:1619-1686`). Each loop iteration, however, creates a fresh manager, fills it once, holds all 32 cleanups, rejects one overflow wrapper, opens the gate, and stops. It does not partially drain and refill the same runtime across multiple waves, so it does not prove that completed reservations are recycled exactly once without cumulative loss while other owners remain gated. The Round 3 remediation description therefore overstates this as multi-wave release coverage.

The active specification also retains stale contradictory wording: line 111 requires the slot to remain reserved until cleanup is fully closed, while line 117 says the cleanup registry retains work “even after a slot is released.” That sentence describes the superseded policy and weakens the test oracle for this exact lifecycle.

**Required resolution:** retain the attempt in the cleanup registry until the same completion action has released its reservation, or transfer the reservation and release callback into the handoff owner so owner shutdown cannot complete first. Add a deterministic barrier proving the stop receipt cannot complete before the release callback. Add a same-manager multi-wave test that drains a controlled subset, admits exactly that many replacements while remaining at 32, repeats the cycle for cancellation and placeholder ownership, rejects every true overflow before claim, then drains to zero with one receipt and exact cancellation counts. Correct the stale normative sentence to match the combined owner contract.

## Verified Correctness and Test Strengths

- Reservation release for construction failure is immediate; every registered attempt otherwise routes release through one guarded `ViewerAdmissionAttemptCleanup` completion, which requires claim completion, core cleanup, and all direct late-channel cancellations.
- The blocked-claim tests prove generation cancellation and stop cannot allow a late returned channel to reinsert or escape direct cancellation, and the slot remains occupied until that path finishes.
- Cancellation, timeout, Reject, Pause, and replacement retain their slot while channel cancellation is gated. The complete timeout-competitor matrix and synchronous receive backpressure remain deterministic and passing.
- The default placeholder owner retains accepted handles, cancels and awaits the same connection core, and prevents additional admission while its 32 cleanups are held.
- The stable-signing project configuration and documentation no longer make the false ad-hoc cross-update claim. The ordinary same-binary login-Keychain lifecycle remains executable and passing.
- The requirement-to-evidence audit truthfully records the stable-signer scenario as pending rather than treating the skipped test as success.

## Independent Validation

- Fresh Viewer app-hosted XCTest: **PASS with one explicit conditional skip**. The `xcresult` summary reported 54 passed, 1 skipped, 0 failed, 0 expected failures, and overall result `Passed`. The test list confirms the sole skip is `testStableSignerUpdateBoundaryProbe` with its packaging-gate reason.
- Focused combined-owner test with `-test-iterations 10`: **PASS**. All ten device/configuration test runs passed with no failure or skip. This demonstrates ordinary stability but does not create the missing completion ordering or same-runtime multi-wave scenario.
- `security find-identity -v -p codesigning`: exit 0 with `0 valid identities found`; the stable-signer probe could not be responsibly executed on this host.
- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 2 — 1 High, 1 Medium, and 0 Low.**
