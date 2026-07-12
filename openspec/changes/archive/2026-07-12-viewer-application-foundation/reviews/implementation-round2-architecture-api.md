# Implementation Review Round 2 — Architecture and API

## Review Scope

This was a fresh review of the complete current `viewer-application-foundation` worktree. It re-read the active proposal, design, capability specifications, tasks, platform architecture, all changed Core and Viewer production sources, the Viewer project/workspace and resources, all Viewer tests, changed Core/SDK tests, documentation, implementation evidence, the Round 1 architecture report, and the remediation record.

The review specifically re-tested the four prior architecture findings and then audited the remediated synchronous listener ingress, claim-in-progress state, cleanup receipt, termination/reset ordering, opaque handoff boundary, future session-manager extensibility, and Core-versus-Viewer ownership.

Severity meanings:

- **High**: an unsafe architecture or requirement failure that invalidates the foundation.
- **Medium**: an actionable ownership or lifecycle defect that violates an explicit requirement or makes the next change unsafe to build upon.
- **Low**: an evidence or maintainability defect that must be corrected before completion but does not invalidate the main architecture.

## Round 1 Finding Verification

| Prior finding | Round 2 result |
| --- | --- |
| Claim-in-progress generation cancellation and Pause/Resume reinsertion | The direct defect is fixed. The attempt and slot are installed before claim, generation membership is removed synchronously, and the exact attempt identity is revalidated after claim (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:464-535`). The deterministic barrier test covers generation cancellation and Pause/Resume (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1088-1135`). A separate shutdown-receipt ownership gap remains as Finding 1 below. |
| No bounded cleanup receipt or reset ordering | The application now has one idempotent receipt, a one-second outer wait, AppKit terminate-later integration, and reset-after-wait ordering (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:41-105,579-608`; `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:59-69,132-137,178-228`; `Viewer/NearWireViewer/App/NearWireViewerApp.swift:40-62`). However, the receipt does not own every claim and handoff path, so this prior finding is not fully closed; see Findings 1 and 2. |
| Synchronous local-network listener failure lost its category | Fixed. The Viewer preserves only the safe `.localNetworkUnavailable` category and collapses other construction errors (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:255-266`), with a separate synchronous-path test (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1258-1286`). |
| Focused secure-transport evidence overstated skipped tests | Fixed in the saved evidence. The result is now stated as the exact result of the recorded command. This review's restricted environment independently skipped five Security/Network-dependent cases and reports that separate result accurately below. |

## Findings

### 1. Medium — The cleanup receipt can complete while a synchronous claim is still in progress and before its returned channel is cancelled

The manager correctly inserts an `Attempt` before calling the potentially blocking `makeAdmissionChannel` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:464-509`). If shutdown occurs while that call is blocked, `stop()` removes the attempt and builds its cleanup task from the removed attempt's core (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:579-608`). At that moment the core has no attached channel. `cancelAndWait()` therefore transitions that core to complete immediately because `beginCancellation` captures a nil channel (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:258-269,317-348`). The cleanup receipt can consequently report `.completed` even though `makeAdmissionChannel` has not returned.

When claim later returns, `attach` fails against the already-cancelled core. The catch path starts a new unstructured `Task` to cancel the returned channel (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:536-543`). That task is not part of the cleanup receipt and is not owned by the manager's cleanup task. Application termination or identity reset may therefore proceed on a receipt that said cleanup completed before the claimed channel has actually been cancelled. If the one-second outer wait expires, the same defect also means the retained cleanup owner does not own this late channel cancellation.

This violates the requirement that window close/termination synchronously close admission and await one cleanup receipt without abandoning cleanup ownership (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:7,21-25`) and the design statement that the receipt owns pending connection cleanup (`openspec/changes/viewer-application-foundation/design.md:35-37`). The Round 1 remediation record overstates this path when it says the receipt awaits exact connection-core cancellation (`openspec/changes/viewer-application-foundation/evidence/implementation-round1-remediation.md:9`).

The claim-race test releases the blocked claim before calling `stop()` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1088-1135`), while the cleanup-receipt test stops only after channel claim and deadline scheduling have completed (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1173-1217`). Neither test covers their intersection.

**Required remediation:** give each pre-claim attempt an idempotent claim-completion cleanup operation installed before `makeAdmissionChannel`. Shutdown cleanup must retain and await that operation, which must either reject the unclaimed wrapper or cancel and await any channel returned after invalidation. The application may still stop waiting after its specified one-second bound, but the same receipt-owned cleanup task must continue until that late claim/channel path terminates. Add a deterministic test that holds claim, calls `stop()`, proves the receipt has not completed, releases claim, delays channel cancellation, and proves receipt completion occurs only after exact cancellation.

### 2. Medium — Handoff transfer and handoff shutdown are separate callbacks with no atomic owner, so cleanup can miss both existing and concurrent handoffs

The handoff API is split into an unrelated synchronous `HandoffConsumer` and asynchronous `HandoffShutdown` closure (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:382-385,427-441`). The live foundation uses the default consumer, which calls `ViewerAdmissionHandle.cancel()`, and an empty `closeHandedOff` closure (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:144-165,427-432`; `Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:20-42`). Handle cancellation only requests asynchronous core cancellation; it exposes no completion to the placeholder owner. After handoff, the attempt is removed from the manager, its slot is released, and only then is the consumer invoked (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:613-629,685-697`). Thus `stop()` has no reference to an already handed-off placeholder core and its empty shutdown closure can complete while that core's channel cancellation is still delayed.

There is also an automatic-admission race: `receivedHello` removes the attempt under the manager lock, unlocks, and then calls `finish(..., handoff: true)` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:613-629`). Shutdown can run between those operations, see neither an attempt nor a registered handoff, finish `closeHandedOff`, and complete its receipt. The consumer can then receive a new handle after shutdown cleanup has completed. The manual `complete` path has the same split transition (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:655-665`), even though current UI calls serialize manual Accept and window close on `MainActor`.

This fails the required single handoff-or-cancel outcome and shutdown ownership (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:105,109-113`) and is unsafe for `viewer-multidevice-flow-control`, whose session manager must be able to atomically reject a transfer once shutdown begins. The current tests show ordinary handoff and an injected shutdown closure independently, but no test delays a handed-off core's cancellation or races transfer with shutdown (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:709-798,1173-1256`).

**Required remediation:** replace the two independent callbacks with one internal handoff owner/coordinator that serializes `transfer` and `shutdown`, can reject-and-cancel a transfer after shutdown begins, and returns an asynchronous cleanup operation covering every accepted handle. Keep an attempt in a transfer state until ownership registration succeeds, and include in-flight transfer plus all owner cleanup in the stop receipt. The foundation placeholder owner must await `connectionCore.cancelAndWait()`, not merely request cancellation. Add deterministic delayed-cancel and transfer-versus-shutdown tests proving no post-shutdown handoff and no receipt completion before handed-off cleanup.

### 3. Medium — Pending-summary coalescing is not generation-aware, so a stopped runtime can republish stale approval UI

Manager operations compute a pending snapshot under the lock but invoke `onPending` only after unlocking (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:555-577,613-665`). A concurrent Hello or terminal callback can therefore compute a nonempty old-generation snapshot, allow `stop()` to remove all attempts and submit `[]`, and then submit the older nonempty snapshot afterward.

`ViewerPendingCoalescer` keeps only a latest array but carries no runtime token, manager identity, revision, or terminal generation marker (`Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:141-178`). The application model creates every manager with the same long-lived coalescer (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:37-42,291-296`) and directly clears `pendingApps` during stop (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:178-205`). A delayed old-manager submission can overwrite that clear on `MainActor`, including after a later runtime starts.

This contradicts the design's stale-callback isolation guarantee (`openspec/changes/viewer-application-foundation/design.md:33-37`) and shutdown's requirement to cancel pending attempts without reviving stopped state (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:7,111`). Latest-only coalescing bounds task count, but it does not establish lifecycle ordering. Existing tests cover stale listener events and direct ingress capacity, not an old pending snapshot delayed across stop or restart.

**Required remediation:** tag every pending publication with a runtime/manager generation and monotonic revision, and make a terminal empty snapshot close that generation so later old submissions are discarded. The application should advance/deactivate the coalescer generation synchronously at stop before clearing UI state. Add deterministic tests that delay a nonempty callback across (a) stop and (b) stop followed by a fresh runtime, and prove no stale row is rendered.

## Architecture and API Checks That Passed

- Core-versus-Viewer ownership remains correct. Core owns platform-neutral wire/transport adaptation and safe Bonjour advertisement events; Viewer owns Keychain identity, listener generation policy, admission, AppKit lifecycle, presentation, and SwiftUI. No Viewer dependency leaked into root `Package.swift` or the podspec.
- The synchronous listener ingress is correctly placed before any `MainActor` task. Inactive, stale, paused, stopped, and full paths reject at the edge, and the 32-slot budget is reserved before channel construction (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:267-284`; `Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:95-139`; `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:464-499`).
- The permanent connection core still owns the immutable callback and continuous decoder. Viewer Hello admission, exact one App Hello, role/negotiation checks, post-Hello rejection, and same-core opaque handle remain structurally aligned with the next-change boundary (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:167-380`).
- Generation replacement now deactivates old ingress and cancels old-generation attempts only after exact replacement commit; replacement failure preserves the old listener and its attempts (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:330-406`).
- Local-network error mapping, pairing/Bonjour ownership, manual Xcode project/workspace boundaries, macOS 13 and Swift 5 settings, identity separation, and internal-only SPI exposure match the active artifacts.
- Identity reset now starts Keychain work only after the bounded runtime cleanup wait returns. A timeout does not reopen admission, and the cleanup task itself remains retained. Findings 1 and 2 concern missing work from that cleanup owner, not the outer wait mechanism.

## Independent Validation

| Command | Result |
| --- | --- |
| `xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' ... test` | Exit 0; result database contained 44 successful test-case runs, 0 failures, 0 skips |
| `swift test --disable-sandbox --quiet -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SecureTransportTests` | Exit 0; 16 executed, 11 passed, 5 environment-dependent skips, 0 failures |
| `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive` | Passed |
| `swift format lint --strict --recursive ...` over all changed Swift source/tests | Passed |
| `git diff --check` | Passed |

The existing passing tests do not cover the three lifecycle orderings described above. The five focused Core skips were caused by unavailable Security/Network trust services in this review environment; the saved implementation evidence records a separate unrestricted run with zero skips.

## Verdict

**Approval withheld.** Round 1 materially improved admission ingress, generation invalidation, cleanup waiting, and error mapping, but cleanup ownership is still incomplete for claim-in-progress and handed-off states, and pending UI delivery is not generation-safe.

**Exact unresolved actionable finding count: 3** — 0 High, 3 Medium, 0 Low.
