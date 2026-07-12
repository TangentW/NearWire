# Implementation Review Round 5 — Architecture and API

## Review Scope

This was a fresh review of the complete current `viewer-application-foundation` worktree after Round 4 remediation. It re-read the active proposal, design, capability specifications, task plan, Viewer and changed Core production source, Viewer tests, the manual project/workspace and resources, product documentation, validation and requirement-audit evidence, all three Round 4 implementation reviews, and `evidence/implementation-round4-remediation.md`.

The review retraced reservation ownership and cleanup ordering through construction failure, claim-in-progress invalidation, policy cancellation, direct late-channel cleanup, accepted handoff, owner shutdown, partial capacity recycling, and final stop. It separately audited the current conditional stable-signer create/deny/verify implementation, including the latest explicit state-root and designated-requirement guards, against its documented three-build command sequence.

## Round 4 Finding Verification

| Round 4 finding | Round 5 result |
| --- | --- |
| A handoff owner and stop receipt could complete before the independent admission reservation release | **Resolved.** Every registered attempt remains in `ViewerAdmissionCleanupRegistry` until its single completion callback releases the exact reservation and then removes the registry entry (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:458-559,731-745`). An accepted handle now retains that same cleanup owner; `cancelAndWait()` waits for core cleanup and then cleanup publication, while owner shutdown waits for every accepted handle (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:144-184,561-625`). The stop receipt concurrently joins the registry and handoff owner, so neither branch can publish completion before slot release (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:833-856`). |
| The burst-ingress test observed channel cancellation rather than cleanup-complete slot release | **Resolved.** The test now awaits the receipt before requiring zero occupied owners (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1571-1606`). Fresh full-suite validation passed without reproducing the Round 4 race. |
| Same-runtime capacity recycling had no deterministic partial-drain/refill proof | **Resolved.** `testHandoffCapacityRecyclesAcrossWavesInOneRuntime` fills 32 accepted owners, closes eight handles and observes 24, admits exactly eight replacements in the same manager, rejects the true overflow before claim, and drains all 40 handles to zero through one receipt (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1882-1951`). The focused receipt/recycling selection passed 20 repeated runs. |
| The conditional update probe did not establish distinct builds/signers or unrelated-signer use, reset, and deletion denial | **Resolved as an executable gate design; external execution remains pending.** The current test requires explicit create/deny/verify phases, token, build identifier, and shared state root; records product path plus team, leaf-certificate, and designated-requirement fingerprints; requires a different product/build and designated requirement for denial; requires an exact matching stable fingerprint for verification; and exercises production-store and exact-selector denial operations (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-775`). The English operator documentation supplies separate DerivedData, identity, team, phase, build, token, and state-root inputs for all three builds (`Documentation/Viewer-Foundation.md:15-31`). |

## Independent Architecture and API Audit

No new actionable architecture or API finding was identified.

### Connection-owner lifetime and exact release

- Capacity remains one shared `ViewerAdmissionBudget` of 32. Reservation occurs under the manager terminal lock before channel claim or per-connection asynchronous work (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:709-745`). The construction-failure path releases its unregistered reservation immediately; every successfully registered path releases only from the cleanup owner's guarded completion callback.
- `ViewerAdmissionAttemptCleanup` requires claim completion, core cleanup, and zero direct late-channel cleanups. `completionPublished` is selected once under one lock, so concurrent finish paths cannot call the release callback twice (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:458-559`). `ViewerAdmissionBudget.release` also removes one concrete reservation and refuses a duplicate removal (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:107-141`).
- Completion publication has the required order: `onComplete()` releases the reservation and removes the registry entry before `completionFinished` is set and handle waiters resume (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:529-550,731-736`). Registry emptiness, handle completion, handoff-owner emptiness, and the stop receipt therefore all happen after the exact slot release.
- Accepted ownership no longer creates a second independent cleanup task without a join edge. The handle retains the attempt cleanup owner, and the registry continues retaining it after transfer. A transfer rejected by shutdown stays on the same cancellation cleanup path (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:946-956`).
- Claim-in-progress and late-returned channels retain the reservation until both claim completion and direct channel cancellation finish. Pause, Reject, timeout, replacement, terminal input, and shutdown all converge on the same idempotent core-cleanup selector rather than releasing policy capacity early.

### Future session-owner compatibility

- `ViewerAdmissionHandle` still grants one consumer right over the original connection core; it does not expose raw Network.framework values, create another decoder, or move callback ownership. Retaining the handle retains the reservation cleanup owner for the active session.
- A future owner may request cancellation early and later call `cancelAndWait()` on the same consumed handle; that path waits for the original core and the reservation-release completion. Retaining already-closed handles does not retain capacity after cleanup, while retaining live handles does.
- `ViewerAdmissionHandoffOwning` continues to serialize `transfer` against `beginShutdown`. The next session manager can add acknowledgement, flow policy, and active operations behind this internal owner without changing the callback/decoder owner or escaping the runtime-wide 32-owner bound.
- Partial release/refill in one live manager demonstrates that the design is a concurrent owner budget rather than a lifetime admission counter. Remaining first-wave owners and replacement owners share the same exact 32-slot pool, and true overflow is still rejected before claim.

### Stable-signer update gate

- The gate is fail-closed when ordinary ad-hoc validation omits `NEARWIRE_SIGNER_PROBE_PHASE`; this remains one explicit conditional skip rather than false persistence evidence.
- Phase, token, build ID, and state root are mandatory. Token/build values are bounded to safe components, and the state root must be the exact standardized `nearwire-viewer-stable-signer-probe` directory under the production Viewer test-container temporary path (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-544,614-624`). Only create makes the token directory; deny only consumes it; verify performs authorized reset and removes it.
- Create records the original installation ID, certificate hash and persistent reference, the test-product path, and the running host's team, signing-certificate hash, and designated requirement. It also proves a real private-key signature (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:546-570,627-672`).
- Deny requires a different build ID, product path, composite signer fingerprint, and specifically a different designated requirement before any destructive probe runs (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:571-585`). It then separately exercises production load, both reset scopes, exact generic-password reads/deletes, exact key lookup/signing/deletion, and exact certificate deletion without relaxing selectors or authentication interaction (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:688-775`).
- Verify requires a different product/build with the complete original stable fingerprint, then proves the original installation ID, certificate, and signing key remain intact before exercising supported TLS-only and full reset (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:587-611`).
- The documented commands use three independent DerivedData products and explicit identity/team overrides while sharing the exact token-scoped state root. The checked-in app itself continues to default to automatic Apple Development signing, with Developer ID as the documented distribution alternative and ad-hoc overrides limited to test/inspection.
- This host has `0 valid identities found`, so the A/unrelated/B gate could not be executed. Tasks 5.1 and 5.4 and the requirement-to-evidence audit correctly remain pending stable-signer execution evidence. That external gate is outstanding completion work, not an unresolved architecture defect in the current implementation or recipe.

### Prior boundaries

- Listener ingress remains synchronous and generation-scoped before `MainActor` work. Pending snapshots remain latest-only and runtime-token scoped. Claim invalidation cannot reinsert a stale connection.
- One connection core still owns the immutable callback, Viewer Hello, continuous bounded decoder, negotiated result, and terminal gate across approval and handoff. No unbounded pre-Hello queue or second decoder owner was introduced.
- Core retains only reusable wire, secure transport, and safe Bonjour adaptation. Viewer retains login-Keychain identity, signing policy, listener generations, admission/owner lifetime, AppKit coordination, presentation, and SwiftUI.
- The manually maintained project remains macOS 13 / Swift 5 mode and links only repository-local `NearWireCore` plus Apple frameworks. No nested manifest, podspec, project generator, Viewer dependency in the root package, Demo placeholder, daemon, menu-bar target, or third-party runtime was added.
- Sandbox, Bonjour/local-network metadata, privacy declarations, truthful unauthenticated-TLS wording, and later-change exclusions remain aligned across specification, source, resources, and documentation.

## Independent Validation

| Command | Result |
| --- | --- |
| Fresh full Viewer app-hosted XCTest using a new DerivedData path and explicit ad-hoc test override | Exit 0; 56 tests total, 55 passed, the stable-signer gate was the sole skip, and 0 failed |
| Focused `testHandoffCapacityRecyclesAcrossWavesInOneRuntime` and `testStopReceiptIncludesAcceptedHandoffCleanup` with `-test-iterations 20` | Exit 0; every repeated run passed |
| `security find-identity -v -p codesigning` | Exit 0; `0 valid identities found`, so no cross-build signer result is claimed |
| `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive` | Passed |
| `swift format lint --strict --recursive` over Viewer and all changed Swift source/tests | Passed |
| English, repository-structure, and module-boundary scripts | Passed |
| `git diff --check` and `plutil -lint` over the Viewer project and resources | Passed |

The Xcode run emitted the expected current-toolchain warnings about macOS 13 XCTest support libraries and ad-hoc test signing. They did not affect build or test success. The conditional stable-signer test was not converted into a success by the ordinary test override.

## Verdict

**Approved.** Round 4 cleanup ordering, exact reservation release, burst-test synchronization, same-runtime capacity recycling, and stable-signer gate-design findings are closed. The future session-owner boundary remains finite and extensible, and no new ownership, API, signing-gate, layer, or packaging defect was found.

The change as a whole must still remain active until the documented three-build gate is run with two valid unrelated signing identities and its exact evidence is saved.

**Exact unresolved actionable finding count: 0.**
