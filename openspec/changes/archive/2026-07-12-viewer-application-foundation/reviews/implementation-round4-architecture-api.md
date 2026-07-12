# Implementation Review Round 4 — Architecture and API

## Review Scope

This was a fresh review of the complete current `viewer-application-foundation` worktree after the combined Round 3 remediation. It re-read the active proposal, design, capability specifications, tasks, Viewer and changed Core production source, the manual Xcode project/workspace, Viewer and transport tests, product documentation, implementation evidence, the three Round 3 implementation reviews, and `evidence/implementation-round3-remediation.md`.

The review specifically traced the connection-owner reservation from pre-claim admission through cancellation, late-channel cleanup, placeholder handoff, owner shutdown, and a future session-manager handoff. It also audited the maintained signing configuration and the conditional cross-build Keychain probe, then rechecked all prior Core/Viewer, callback/decoder, generation, shutdown, and packaging boundaries.

Severity meanings:

- **High**: an unsafe architecture or requirement failure that invalidates the foundation.
- **Medium**: an actionable contract or release-gate defect that leaves a required boundary unproved or unsafe to extend.
- **Low**: an actionable evidence or maintainability defect that must be corrected before completion but does not invalidate the production architecture.

## Round 3 Architecture and Cross-Dimension Finding Verification

| Prior concern | Round 4 result |
| --- | --- |
| The 32-slot bound ended at the admission decision and excluded asynchronous cancellation and placeholder handoff cleanup | **Resolved in production architecture.** A reservation is now released only by `ViewerAdmissionAttemptCleanup` after claim completion, core cleanup, and any direct late-channel cleanup complete (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:451-531,687-727`). Accepted handoff starts the same cleanup owner waiting on the same core before policy ownership leaves the registry, and the placeholder owner cancels and awaits the handle (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:534-599,919-927`). The 32-slot budget therefore remains occupied while a terminal connection is still cancelling or placeholder-owned. One stale deterministic assertion remains as Finding 2. |
| The next session manager could escape the finite owner bound | **Resolved structurally.** `ViewerAdmissionHandoffOwning.transfer` receives only a single-consumer handle retaining the original core. The attempt cleanup task continues to retain the reservation independently of the live-attempt dictionary and cleanup registry until that core actually closes. A future owner can retain the handle for an active session without acquiring a second slot or releasing the first one, and `beginShutdown()` is the serialized close-and-join boundary (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:139-178,451-531,534-599,919-927`). |
| Maintained ad-hoc builds were incorrectly treated as proof of persistent login-Keychain access | **The production project contract is corrected.** Debug and Release app configurations now use automatic `Apple Development` signing, while the team remains repository-local operator configuration; ad-hoc signing appears only as an explicit validation-command override (`Viewer/NearWireViewer.xcodeproj/project.pbxproj:172-175`). The active artifacts and operator documentation consistently require the same supported Apple Development or Developer ID signer across maintained updates and do not count ad-hoc inspection as persistence evidence. Cross-build evidence correctly remains pending. The conditional probe itself is incomplete; see Finding 1. |

## Findings

### 1. Medium — The conditional update-boundary probe cannot prove the complete unrelated-signer contract

The active requirement says an unrelated signer cannot non-interactively read, use, reset, or delete the Viewer records (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:29,40-44`). The conditional probe's unrelated-signer branch performs only one broad assertion that `store.loadOrCreate()` throws, then returns (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:522-547`). That call begins by reading the installation generic-password item (`Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:137-146,177-190`), so an early denial does not exercise exact private-key lookup/signing use, `resetTLSIdentity()`, `resetAllIdentity()`, certificate deletion, private-key deletion, or generic-password deletion. The later same-signer branch can detect incidental mutation caused by that one load attempt, but it cannot establish that the explicit reset/delete APIs are denied because the unrelated build never invokes them.

There is also no committed command sequence or packaging harness defining how build A, the unrelated-signer build, and build B must use separate products while sharing the probe token and preserved Keychain state. The XCTest skip calls this a packaging gate (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-530`), but the saved remediation explicitly says no driver was added and records only the ordinary ad-hoc command that skips it (`openspec/changes/viewer-application-foundation/evidence/implementation-round3-remediation.md:9,14`; `evidence/implementation-validation.md:47-54`). Even once two signing identities are available, the current probe and evidence recipe are therefore insufficient to satisfy the normative scenario.

**Required remediation:** make the conditional gate reproducible and cover every security operation. Record or automate an exact separate-build sequence for stable signer A, unrelated signer B, and a fresh stable-signer-A build. In the unrelated phase, independently prove denial of exact installation/metadata reads, exact private-key lookup and signing use, TLS reset, full reset, and the underlying exact deletions without broadening selectors. Then have build B prove that the original installation ID, certificate, and private-key signing use remain intact before exercising the two supported reset scopes. Keep the gate explicitly pending or skipped when the required identities are unavailable.

### 2. Low — One burst-admission test still assumes that cancellation notification releases the owner slot synchronously

`testListenerAdmissionIngressBoundsBurstBeforeMainActorWork` calls `manager.stop()`, waits only for the fake channels' cancellation callbacks, and immediately requires `occupiedCount == 0` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1378-1410`). Under the corrected owner contract, the callback runs inside `FakeAdmissionChannel.cancel()` before the core serial queue publishes cleanup completion and before `ViewerAdmissionAttemptCleanup` releases the reservation (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:2275-2279`; `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:336-344,508-531`). The assertion therefore races the intentional asynchronous release boundary.

A fresh full-suite run failed at line 1409 with `XCTAssertEqual failed: ("1") is not equal to ("0")`; 55 tests ran, with 53 passing, 1 explicit stable-signer skip, and this 1 failure. An immediate isolated rerun of the same test passed, confirming that the current saved claim of a deterministic 54-pass suite is not reproducible. The production reservation lifetime is correct; the test is observing the wrong completion signal.

**Required remediation:** retain the receipt returned by `stop()`, await its completion, and only then assert zero occupied owners. Re-run the entire Viewer suite from a fresh result bundle and update the saved exact result. Do not add a polling delay or release the slot earlier, because either would weaken the corrected cleanup-lifetime contract.

## Architecture and API Checks That Passed

- The connection-owner reservation is installed before the potentially blocking claim and is released exactly once only after claim, direct late-channel, and core cleanup complete. The 33rd wrapper is rejected before channel construction while 32 earlier owners are still cancelling or placeholder-owned.
- Attempt policy removal and resource cleanup remain separate without losing ownership. The manager registry owns claim/cancellation work; accepted handoff moves policy ownership to the serialized handoff owner while the cleanup task independently retains the slot until the same core closes.
- The future session-manager boundary preserves one immutable callback/decoder owner and one finite connection-owner slot. It can extend the opaque handle/core internally with acknowledgement, flow policy, and active operations without exposing Network.framework values or constructing a replacement decoder.
- Handoff transfer and shutdown remain atomic through one owner. A rejected transfer stays on the attempt cancellation path; an accepted transfer is registered before success and is joined by owner shutdown.
- Listener ingress remains synchronous, generation-scoped, paused/stopped aware, and ahead of `MainActor` work. Claim invalidation, late-channel cleanup, pending-summary coalescing, and runtime-token checks retain the Round 3 lifecycle fixes.
- Viewer Hello, App Hello, negotiation state, post-Hello input rejection, terminal gate, and all channel events remain serialized on the original connection core with bounded decoding and no unbounded event queue.
- The manually maintained project remains macOS 13 / Swift 5 mode, references only the repository-local `NearWireCore` product, and adds no nested manifest, podspec, project generator, third-party runtime, Demo placeholder, daemon, or menu-bar target.
- Core retains only reusable wire, transport, and safe Bonjour adaptation. Login-Keychain identity, stable-signing policy, listener generations, admission ownership, AppKit coordination, presentation, and SwiftUI remain Viewer-owned.
- Automatic Apple Development signing is the checked-in maintained default. The lack of a repository-wide `DEVELOPMENT_TEAM` is appropriate for an internal team-selected project, and ad-hoc overrides are accurately limited to isolated testing and structural inspection.

## Independent Validation

| Command | Result |
| --- | --- |
| Full ad-hoc Viewer XCTest run with a fresh DerivedData path | Exit 65; 55 tests ran: 53 passed, 1 stable-signer probe skipped, and `testListenerAdmissionIngressBoundsBurstBeforeMainActorWork` failed at line 1409 because one owner slot had not yet released |
| Isolated rerun of `testListenerAdmissionIngressBoundsBurstBeforeMainActorWork` against the same build | Exit 0; passed, demonstrating the ordering-sensitive assertion |
| `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive` | Passed |
| `git diff --check` | Passed |
| `plutil -lint` over the Viewer project, Info.plist, entitlements, and privacy manifest | Passed |
| Release `-showBuildSettings` review command | This review environment could not resolve SwiftPM caches because its sandbox denied the default user cache paths; the committed project and saved prior output both show `CODE_SIGN_STYLE = Automatic` and `CODE_SIGN_IDENTITY = Apple Development` |

The stable-signer update gate was not run because this host has no valid signing identity, as already recorded in the active evidence. This review does not treat that conditional skip, the prior ad-hoc release inspection, or static project settings as proof of cross-update Keychain behavior.

## Verdict

**Approval withheld.** The production connection-owner architecture, future session-manager ownership, automatic maintained-signing configuration, and all prior layer/lifecycle boundaries are structurally sound. Completion still requires a conditional probe that covers the full unrelated-signer contract and a deterministic full-suite result aligned with the new cleanup boundary.

**Exact unresolved actionable finding count: 2** — 0 High, 1 Medium, 1 Low.
