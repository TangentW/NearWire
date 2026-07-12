# Implementation Review Round 3 — Architecture and API

## Review Scope

This was a fresh review of the complete current `viewer-application-foundation` worktree after Round 2 remediation. It re-read the active proposal, design, capability specifications, tasks, all changed Core and Viewer production source, the manual Xcode project/workspace and resources, all Viewer and changed Core/SDK tests, product documentation, validation and audit evidence, every Round 2 implementation report, and `evidence/implementation-round2-remediation.md`.

The review traced every prior architecture finding through production code and deterministic tests, then independently audited listener ingress, lifecycle ownership, terminal effects, claim-in-progress cleanup, handoff/shutdown atomicity, generation isolation, continuous decoder ownership, Core-versus-Viewer boundaries, and the extension point for `viewer-multidevice-flow-control`.

## Round 2 Architecture Finding Verification

| Prior finding | Round 3 result |
| --- | --- |
| Cleanup receipt could complete before a claim-in-progress returned and its late channel was cancelled | **Resolved.** Each attempt now registers a cleanup owner before synchronous claim. The owner separately tracks claim completion, core cleanup, and direct late-channel cleanup, and remains in a manager-owned registry until all three are complete (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:411-529,679-767`). `stop()` awaits that registry independently of the live admission dictionary (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:801-824`). Deterministic tests hold claim and channel cancellation across stop and prove the same receipt times out, remains responsible, and later completes after exactly one cancellation (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1395-1505`). |
| Handoff transfer and shutdown were separate non-atomic callbacks | **Resolved.** One `ViewerAdmissionHandoffOwning` boundary owns both synchronous transfer and asynchronous shutdown (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:531-596`). Manager transfer occurs while its terminal lock remains held; shutdown closes the same owner while holding that lock, so no attempt can occupy an untracked transfer gap (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:801-824,829-845,871-884,915-923`). The placeholder owner registers accepted handles before returning and awaits `cancelAndWait()` for each. Delayed accepted-handoff cleanup is included in the stop receipt (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1507-1548`). |
| Pending summaries could cross runtime generations and revive stale UI | **Resolved.** Every runtime constructs a new coalescer, delivery checks the exact runtime token, and stop synchronously deactivates and drops that coalescer before clearing UI state (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:135-152,180-210,295-303`). The coalescer is latest-only, delivers one snapshot per MainActor turn, and refuses all submissions after deactivation (`Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:143-204`). Its deterministic test proves both MainActor fairness and deactivated-generation suppression (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:749-783`). |

## Independent Architecture Audit

No new actionable architecture or API finding was identified.

The following properties were independently verified:

- Listener callbacks synchronously cross the generation/capacity ingress before any `MainActor` task. The active-generation check, 32-slot reservation, attempt record, and cleanup owner are installed before channel claim. A stale, paused, stopped, or over-capacity wrapper is rejected at the edge.
- Claim invalidation is closed under Pause/Resume, generation replacement, failure, timeout, Reject, and shutdown. An invalidated claim cannot reinsert itself; any channel returned late remains owned by its attempt cleanup record until direct cancellation completes.
- Admission-terminal removal and resource cleanup are deliberately separate. Capacity is released exactly once at the handoff-or-cancel terminal decision, while the cleanup registry continues to own already-cancelling work until completion, as required by the active specification (`specs/viewer-application-foundation/spec.md:105-111`).
- Channel input is synchronously backpressured into the permanent core's private serial queue. The immutable callback, one bounded decoder, negotiated result, and terminal state remain on that core across approval and handoff; no second callback or decoder owner appears.
- Automatic and manual handoff transfer are serialized with shutdown. Accepted ownership moves from the attempt registry to the handoff owner without a gap; a transfer rejected after shutdown remains on the attempt cleanup path.
- The placeholder handoff owner closes and awaits the same core. Its protocol is a suitable internal extension point for the next session-manager change: the next owner can add acknowledgement and active-session operations without exposing Network.framework values or replacing callback/decoder ownership.
- Pending UI delivery is bounded and generation-scoped. Deactivation plus runtime-token validation prevents old-manager snapshots from affecting a stopped or replacement runtime, and one-yield-per-snapshot avoids a single unbounded MainActor drain.
- Window close, Retry, identity reset, and AppKit termination share the same idempotent receipt and one-second outer bound. A timeout never reopens ingress and does not discard the registry or handoff owner's eventual cleanup responsibility.
- Core owns only reusable protocol/transport adaptation and safe Bonjour advertisement events. Viewer owns login-Keychain identity, listener-generation policy, admission, handoff lifecycle, AppKit coordination, presentation, and SwiftUI. No Viewer implementation or dependency leaked into the root package or podspec.
- The Round 2 correctness and security remediations are compatible with these boundaries: canonical certificate time parsing, portable exact-key validation, non-interactive exact identity lookup/deletion, removal of the broad identity fallback, synchronous pre-Hello backpressure, privacy metadata, and deterministic terminal-race tests introduce no public SDK or cross-layer ownership regression.
- The manual Viewer project remains macOS 13 / Swift 5 mode, links only the repository-local `NearWireCore` product and Apple frameworks, and is referenced from the root workspace without a nested package, podspec, generator, Demo placeholder, daemon, or menu-bar target.

## Independent Validation

| Command | Result |
| --- | --- |
| `xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' ... test` | Exit 0; action succeeded; 53 test statuses were `Success`, with no failed or skipped status |
| `swift test --disable-sandbox --quiet -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SecureTransportTests` | Exit 0; 16 executed, 11 passed, 5 environment-dependent Security/Network skips, 0 failures |
| `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive` | Passed |
| `swift format lint --strict --recursive ...` over all changed Swift production and test source | Passed |
| `plutil -lint` over Viewer Info.plist, entitlements, privacy manifest, and project file | Passed |
| `./Scripts/verify-english.sh` | Passed |
| `git diff --check` | Passed |

The focused Core skips are limitations of this review agent's restricted Security/Network environment. The saved implementation evidence records a separate unrestricted focused run with all 16 passing, and the current architecture conclusions do not depend on treating a skipped test as passed.

## Verdict

**Approved.** The Round 2 architecture findings are closed in code and deterministic tests, the continuous-core handoff remains extensible, and no unresolved ownership, lifecycle, boundary, or API issue was found.

**Exact unresolved actionable finding count: 0.**
