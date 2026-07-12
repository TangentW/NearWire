# Implementation Review Round 2 — Architecture and API

Date: 2026-07-13

## Scope

Reviewed the current uncommitted implementation of `viewer-multidevice-flow-control` after Round 1 remediation. The review read `AGENTS.md`, the active proposal, design, capability specification, tasks, the Round 1 architecture/API report, the complete current Core decoder/channel seams, Viewer admission/session/manager implementation, focused tests, application integration, and relevant documentation. No production, test, specification, or task source was modified; this report is the only file added by this review.

Severity meanings:

- **High:** an ownership or API defect that invalidates the architecture boundary or can corrupt/couple sessions.
- **Medium:** a concrete lifecycle, scheduling, isolation, or protocol-resource defect that violates a normative requirement and must be fixed before completion.
- **Low:** a bounded internal contract or concurrency-discipline defect that is not currently exercised by the live path but should be corrected before approval.

## Round 1 Remediation Status

| Round 1 finding | Round 2 status |
| --- | --- |
| Recorded policy timeout resumes receive | **Resolved structurally.** `decoderDidProgress` now returns `terminalWithoutResume`; the core synchronously begins cancellation and returns before ordinary progress can resume the token (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:267-282`; `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:590-603`). |
| Multiple session wakes, uplink stall, and zero-rate polling | **Resolved structurally.** One generation-checked `serviceWake` now chooses policy, queue-expiry, token, and batch deadlines, while zero downlink rate contributes no batch/token wake (`ViewerMultiDeviceSession.swift:121-124,579-657`). A new aggregate per-turn-budget defect remains as Finding 2 below. |
| Mailbox rejection closes instead of retrying | **Not fully resolved.** Advisory preflight and a blocked flag were added, but authoritative admission backpressure still closes and the focused retry test fails; see Finding 1. |
| Policy timeout sleeps a fresh ten seconds | **Resolved.** The session stores the absolute deadline and the unified wake sleeps until that deadline through the injected scheduler (`ViewerMultiDeviceSession.swift:426-446,579-598`). |
| Active-ingress cross-limit validation absent | **Substantially resolved.** Session construction now checks the actual receive chunk, encoded Event-frame limit, overflow, and the 19 MiB hard cap before attachment (`ViewerMultiDeviceSession.swift:167-177`). The live 2 MiB default is no longer used after attachment; see Finding 3. |
| Legacy/resumable decoder APIs can reorder retained input | **Resolved.** The decoder records one consumption mode and terminally rejects a mode switch while input is retained, with a focused transition test (`Core/Sources/NearWireTransport/WireFrame.swift:65-80,451-467`; `Core/Tests/NearWireTransportTests/WireFrameTests.swift:192-219`). |

## Findings

### 1. Medium — Authoritative mailbox backpressure still selects terminal state, and the retry test does not make progress

`drainDownlink` now asks `canAdmitSessionSend` before admission and leaves the tentative queue, scheduler, bucket, and sequence uncommitted when that advisory predicate is false (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:701-769`). However, the predicate is explicitly advisory: the real mailbox admission remains the ownership boundary. `SecureSendMailbox.admit` can still throw `SecureTransportError(code: .backpressure)` when its count or byte reservation cannot be satisfied (`Core/Sources/NearWireTransport/SecureByteChannel.swift:554-607`). Any error from the authoritative `core.admitSessionSend` call is caught by the outer generic catch and converted to `.localAdmissionFailure`, closing and clearing the session (`ViewerMultiDeviceSession.swift:760-775,787-799`).

That is the same forbidden state transition from Round 1 whenever capacity changes after preflight or a conforming channel reports capacity only through the admission result. The retry mechanism is also not currently executable evidence: the new `testDownlinkMailboxBackpressureRetriesWithoutSequenceGapOrDisconnect` consistently times out waiting for the post-progress Event and then decodes the previous non-Event frame (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:314-340`). The focused Round 2 command reproduced this failure twice, including once in isolation.

**Required fix:** make the authoritative admission API expose a typed result that distinguishes transient bounded capacity from invalid configuration/terminal state, or catch `SecureTransportError.code == .backpressure` explicitly. A transient rejection must set blocked ownership, commit none of the planned values, and wait for a generation-matched mailbox-progress notification; it must not close. Diagnose the current no-progress retry and make the focused test pass while additionally exercising a predicate-success/admission-backpressure race and an earlier admitted frame followed by rejection.

### 2. Medium — The unified wake has no aggregate record budget for one service turn

The specification gives scheduled uplink publication, expiry, and queue service one default budget of 128 records per turn, with a hard maximum of 512. `serviceSession`, however, invokes three independently bounded stages in one core-queue turn (`ViewerMultiDeviceSession.swift:607-623`):

- `serviceQueueExpirations` authorizes up to 128 expirations from the uplink queue and another 128 from the downlink queue (`ViewerMultiDeviceSession.swift:677-695`);
- `deliverUplink` may dequeue and hand off another 128 records (`ViewerMultiDeviceSession.swift:534-573`);
- `drainDownlink` may dequeue and encode a batch of up to 256 records because the batch scheduler is configured independently (`ViewerMultiDeviceSession.swift:193-200,701-749`).

One wake can therefore process up to 640 queue records before yielding, exceeding both the 128 default and 512 hard service-turn bounds. The single-task ownership repair is sound, but it does not provide the finite aggregate work contract needed by that scheduler. At high accepted rates and with both queues populated, one session can hold its sole protocol executor substantially longer than specified.

**Required fix:** create one per-turn service budget, pass its remaining allowance through expiration, uplink delivery, and downlink preparation, and stop/yield when it is exhausted. Keep the existing one-wake ownership and schedule one successor only if eligible work remains. Add a deterministic mixed-work test that starts with due expirations plus deliverable uplink and downlink records and proves the combined committed/inspected count never exceeds 128 (and never exceeds the configurable hard maximum).

### 3. Low — Attached live sessions replace the specified 2 MiB ingress default with a smaller derived value

`ViewerSessionIngressLimits.default` remains 2 MiB (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:55-61`), but every real `ViewerDeviceSession` replaces it with exactly `maximum event frame + 2 * receive chunk` (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:167-177`). With the live default frame and 64 KiB receive chunk this is approximately 1.125 MiB, not the normative 2 MiB live default. The derived expression is a valid minimum cross-layer proof and stays below 19 MiB, but it silently changes the specified operating budget rather than validating the default against that proof.

No presently legal default frame appears to be rejected by the smaller derived value, so this is a bounded contract mismatch rather than a demonstrated protocol failure.

**Required fix:** retain 2 MiB as the live configured default and validate that it is at least the derived requirement; use a larger derived value only for an explicitly supported wider configuration, still capped at 19 MiB. Add exact default, derived-boundary, overflow, and incoherent-configuration assertions.

### 4. Low — The mutable snapshot handler is read outside its synchronization boundary

`ViewerMultiDeviceSessionManager` is `@unchecked Sendable` and permits replacement of `onSnapshots` under its lock (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSessionManager.swift:5,28-32,55-60`). Every later publication constructs the snapshot under the lock, unlocks, and then reads the mutable `onSnapshots` property to invoke it (`ViewerMultiDeviceSessionManager.swift:116-131,234-248,251-300,318-339`). Concurrent `setSnapshotHandler` and publication therefore race on the closure reference even though callback invocation itself correctly occurs outside the registry lock.

The live application currently installs the handler before listener startup (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:191-200`), which limits exposure, but the manager API and its unchecked sendability do not enforce that ordering.

**Required fix:** snapshot both the callback and immutable snapshot array while holding the manager lock, then invoke the captured callback after unlocking; alternatively make the handler immutable at construction. Add a concurrency test that replaces/publicates without a data race or callback-under-lock reentrancy.

## Architecture Checks That Passed

- The same admission core, secure callback, resumable decoder, and terminal gate remain the only byte/protocol owners across synchronous reentrant handoff. Approval-mode coalesced input is retained until attachment and the focused approval test passes.
- Recorded-timeout partial/drained progress now has a synchronous terminal-without-resume disposition. Terminal cleanup clears the decoder, retained receipt, continuation, and pause token before notifying session/manager owners.
- The generation-bound secure receive token remains idempotent, and mode-switch protection closes the decoder API ambiguity without changing supported SDK API.
- The 16-entry manager still counts provisional, negotiating, active, and disconnecting ownership through exact handle cleanup. Live-route uniqueness, 64 recent rows, one recent-expiry wake, and connection-bound downlink targeting remain structurally intact.
- Manager registry locks are released before core attachment, session operations, cleanup waits, and user callbacks. Apart from the mutable callback-reference race in Finding 4, no manager/core lock-order inversion was found.
- Core additions remain platform-neutral SPI, Viewer policy/lifecycle/UI remains under `Viewer`, and no third-party Core/SDK dependency, nested package manifest, wire-schema change, or supported SDK API expansion was introduced.
- The uplink sink now crosses a bounded one-batch asynchronous handoff, so a blocked sink no longer blocks the session's protocol executor; its focused control-progress test passes.

## Focused Validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -only-testing:NearWireViewerTests/ViewerFlowControlTests
```

Result: build succeeded and 17 focused tests ran. Sixteen tests passed. `testDownlinkMailboxBackpressureRetriesWithoutSequenceGapOrDisconnect` failed with two assertions (one unexpected decode error), so the command exited 65. Re-running only that test reproduced the same failure. A preceding run without `CODE_SIGNING_ALLOWED=NO` was cancelled before compilation because the local project has no development team configured; it is not counted as product validation.

The focused suite now covers several remediation paths, but it still does not contain the Round 1 required recorded-timeout partial/drained no-resume driver test, aggregate scheduled-service budget test, active-ingress boundary matrix, or predicate-success/admission-backpressure race.

## Verdict

**Approval withheld.** Five of the six Round 1 architecture findings are structurally resolved, but mailbox backpressure remains incomplete. The new unified scheduler also exceeds its aggregate per-turn work contract, and two bounded internal API/concurrency mismatches remain.

**Exact unresolved actionable finding count: 4 — 0 High, 2 Medium, 2 Low.**
