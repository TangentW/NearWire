# Implementation Review Round 1 — Architecture and API

## Review Scope

This review independently inspected the complete worktree diff for `viewer-application-foundation`, including the active proposal, design, capability specification, tasks, platform architecture, Core and Viewer production sources, the manually maintained Xcode project/workspace, tests, documentation, and saved implementation evidence. The review focused on ownership boundaries, admission lifecycle semantics, the continuous connection-core handoff, future session extensibility, and exact conformance to the active specification.

Severity meanings used below:

- **High**: unsafe architecture or a requirement failure that blocks the intended foundation.
- **Medium**: actionable correctness or lifecycle gap that violates an explicit requirement or makes the next change unsafe to build upon.
- **Low**: evidence, documentation, or maintainability defect that must be corrected before completion but does not invalidate the main architecture.

## Findings

### 1. Medium — A claimed but not-yet-registered attempt can survive listener replacement or Pause followed by Resume

`ViewerAdmissionManager.admit` reserves a slot and releases the manager lock before it constructs and claims the incoming channel (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:327-355`). The attempt is not inserted into `attempts` until the channel has already been claimed and attached (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:357-378`). During that interval, `cancelGeneration` can only remove attempts already present in the dictionary (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:404-410`). It records no invalidated-generation epoch or tombstone. A replacement commit invokes that method and then cancels the old listener (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:288-293`), but listener cancellation cannot recover a wrapper already claimed by the admission path.

Consequently, an old-generation admission blocked inside `makeAdmissionChannel` can be missed by replacement cancellation, later pass the `!shutdown && !paused` recheck, enter `attempts`, and proceed to handoff. The same window exists for Pause: `setPaused(true)` misses the unregistered attempt, and if Resume occurs before the post-claim check, the attempt passes because only the current Boolean is checked (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:394-400`).

This violates the required transition semantics that Pause cancels all claimed/pre-Hello attempts and replacement commit cancels every non-handed-off old-generation attempt (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:103`, scenarios at lines 145-160; `openspec/changes/viewer-application-foundation/design.md:75-83`). It also means completed tasks 4.3 and 5.1 do not yet have evidence for the claimed listener-generation race coverage (`openspec/changes/viewer-application-foundation/tasks.md:22,26`). Existing tests pause or cancel generations only after channels have started and attempts are registered (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:907-961`), so they do not exercise this interval.

**Required remediation:** make pre-claim reservation/attempt registration participate in the manager's terminal state machine, or capture and revalidate monotonic pause and generation epochs after channel construction. A cancellation operation must be able to terminally mark an in-flight reserved attempt even while wrapper claim is blocked. Add deterministic barrier-based tests that hold `makeAdmissionChannel` across (a) replacement commit and (b) Pause followed by Resume, then prove no start/handoff occurs and the exact slot is released once.

### 2. Medium — Shutdown and identity reset have no cleanup receipt, so reset can delete identity while owned channel cancellation is still pending

`ViewerAdmissionConnectionCore.cancel` only enqueues work on its private queue; that work calls `finish` and starts another unstructured task for `channel.cancel()` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:165-170`). `ViewerAdmissionManager.stop` removes attempts and calls that asynchronous cancellation path but returns no completion receipt (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:413-423,487-500`). `ViewerApplicationModel.stopRuntime` immediately reports `.stopped` (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:160-174`), and `resetIdentity` immediately begins the Keychain deletion/recreation operation after calling it (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:176-193`).

The admission gate does prevent new handoffs, but there is no bounded opportunity to observe that owned channel cleanup has completed before the TLS identity is deleted or application termination proceeds. This is narrower than an unbounded wait requirement: the design explicitly calls for a short bounded cleanup opportunity (`openspec/changes/viewer-application-foundation/design.md:33-37`), the application requirement says closing/termination finishes bounded cleanup (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:7`), and reset requires listener/admission to stop before deletion (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:27`). The current lifecycle test checks only that status changes synchronously to `.stopped` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:38-73`); it does not prove cleanup ordering or a bound.

This missing API contract also weakens the next change: the future session owner will need an observable bounded shutdown result, while the current `closeHandedOff` and admission stop surfaces are fire-and-forget.

**Required remediation:** introduce an internal asynchronous cleanup receipt/barrier that closes admission first, waits for each owned connection core/channel cancellation acknowledgement up to a fixed documented bound, and reports completion versus timeout without reopening the gate. Identity reset must await that barrier before deleting Keychain material. Last-window/application termination must grant the same bounded opportunity using an appropriate macOS termination lifecycle. Add deterministic delayed-channel tests for successful cleanup, timeout behavior, exact-once completion, and reset deletion ordering.

### 3. Medium — Synchronous local-network listener creation failures lose their recoverable error category

Core deliberately maps a local-network permission failure thrown while constructing `NWListener` to `SecureTransportError.Code.localNetworkUnavailable` (`Core/Sources/NearWireTransport/SecureByteChannel.swift:645-680`). The Viewer catches every error from `identity.makeListener` and rewrites it to `.listenerUnavailable` (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:220-227`). Only asynchronous `.failed` listener events retain the specific category (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:272-276`).

The result depends on where Network.framework reports the same failure: construction-time denial cannot reach the required fixed local-network recovery guidance, despite the explicit startup-denial scenario (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:181,191-194`). This is an ownership-boundary issue because Core supplies a safe typed error specifically for Viewer presentation, but the adapter erases it.

**Required remediation:** map a construction-time `SecureTransportError` with `.localNetworkUnavailable` to `ViewerPresentationError.localNetworkUnavailable`, while continuing to collapse all other construction errors to the safe generic listener category. Add an application-model test whose listener factory throws that typed error and assert the fixed local-network presentation; retain the asynchronous failure-event test as a separate path.

### 4. Low — Focused secure-transport evidence says all tests passed even though five were skipped

The saved evidence states, “All 16 secure transport tests passed,” and specifically includes production TLS/ALPN coverage (`openspec/changes/viewer-application-foundation/evidence/implementation-validation.md:95-101`). An independent run of the same focused command executed 16 tests with 0 failures and 5 skips. The skipped cases include connection-local trust and production TLS 1.3/ALPN integrations under the restricted environment. Exit success is genuine, and the broader canonical evidence may supply those gates elsewhere, but skipped tests are not passed tests and the focused result must not claim otherwise.

**Required remediation:** update the focused evidence with the exact executed/passed/skipped counts and name the environment limitation. If another recorded command supplies the skipped integration evidence, cross-reference that distinct result rather than attributing it to this command. Reconcile task 5.4 only after the evidence wording is exact.

## Architecture and API Checks That Passed

- The repository boundaries are respected: platform-neutral transport and wire behavior remain in `Core`; identity, admission policy, application lifecycle, and UI remain in `Viewer`; no nested package manifest or podspec and no root package dependency were introduced.
- The permanent admission-core approach is structurally correct. One core exists before channel construction, the immutable callback weak-routes to it, one bounded decoder remains installed, Viewer Hello is admitted at TLS readiness, and the opaque handoff retains the same core. The next session change can extend that owner without replacing callback or decoder ownership (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:80-250`; specification lines 97-105).
- The 32-slot shared budget, pre-claim reservation, same-deadline approval path, exact slot release, automatic/confirmation decision boundary, and opaque handoff API are otherwise aligned with the active design.
- Bonjour advertisement shaping and exact registration matching are owned by internal Core transport SPI, while pairing-code generation and listener-generation policy remain Viewer concerns.
- The manually maintained project/workspace has the intended macOS application/test ownership and repository-local Core linkage, without leaking Viewer-only build concerns into the root Swift Package.
- The Viewer installation identity and TLS identity implementation remain separate and internal; no new public SDK surface or accidental bootstrap API was introduced.

## Independent Validation

The following commands were run independently against the reviewed worktree:

| Command | Result |
| --- | --- |
| `xcodebuild -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Debug test` (with the repository's evidence-equivalent destination/build settings) | Passed; 34 tests executed, 0 failures, 2 skips |
| `swift test --filter SecureTransportTests` (with the repository's strict-concurrency flags) | Exit 0; 16 tests executed, 0 failures, 5 skips |
| `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive` | Passed |
| `./Scripts/verify-english.sh` | Passed |
| `git diff --check` | Passed |

Passing compilation and the existing test suite do not cover Findings 1 and 2 because the necessary claim-in-progress and delayed-cleanup barriers are absent.

## Verdict

**Approval withheld.** The chosen ownership boundaries and continuous-core handoff architecture are suitable, but the lifecycle state machine is not yet closed under replacement/Pause races, shutdown/reset lacks the specified bounded cleanup contract, and one typed recoverable error is erased at the Core-to-Viewer boundary.

**Exact unresolved finding count: 4** — 0 High, 3 Medium, 1 Low.
