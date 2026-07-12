# Implementation Review Round 2 — Correctness and Testing

Date: 2026-07-13

## Scope

Independently reviewed the current uncommitted `viewer-multidevice-flow-control` implementation after Round 1 remediation. The review covered the active OpenSpec artifacts, the Round 1 correctness report, Core frame-decoder and secure-channel changes, Viewer admission/session/manager code, the expanded Core and Viewer tests, and the current evidence directory. No production, test, or specification source was modified; this report is the only added file.

Severity meanings:

- **High:** data/protocol corruption or an unsafe ownership defect that blocks the change.
- **Medium:** an actionable requirement violation, stalled progress path, race, or missing release evidence that must be resolved before completion.
- **Low:** a bounded correctness or test-quality issue that does not invalidate the main architecture.

## Round 1 Finding Status

- `NW-MFC-CT-I1-001` is resolved for a **complete** frame coalesced after App Hello. `scheduleInputContinuation` now retains the pause token while approval is pending, and `ViewerDeviceSession.start()` explicitly resumes same-core continuation after policy state is installed. The new approval/coalescing test passes.
- `NW-MFC-CT-I1-002` is resolved. Decoder progress now returns `terminalWithoutResume`; the core begins cancellation before applying ordinary `needsMoreBytes`/`drained` resume behavior.
- `NW-MFC-CT-I1-003` is resolved in implementation. Policy deadlines are part of the single absolute-deadline service wake rather than a fresh ten-second sleep after admission.
- `NW-MFC-CT-I1-004` remains unresolved in observable behavior. The new focused mailbox-retry test fails consistently; see `NW-MFC-CT-I2-001`.
- `NW-MFC-CT-I1-005` is resolved in implementation structure. One replaceable service wake now considers policy, queue expiry, uplink token, downlink batch, and downlink token deadlines, and zero-rate business work does not install a batch polling wake. The required broader scheduling matrix remains missing under `NW-MFC-CT-I2-005`.
- `NW-MFC-CT-I1-006` remains unresolved. Test coverage expanded from 6 to 17 Viewer tests, but it is still substantially short of Tasks 5.1–5.5 and currently contains a failing regression test.
- `NW-MFC-CT-I1-007` is resolved. The manager overlays the current persisted nickname on every incoming session snapshot, and a focused regression test passes.

## Findings

### NW-MFC-CT-I2-001 — Medium — Mailbox-capacity recovery does not produce the required atomic retry

The revised downlink path now checks `canAdmitSessionSend`, leaves queue/scheduler/token/sequence copies uncommitted when capacity is unavailable, records `downlinkMailboxBlocked`, and clears that flag when `sessionMailboxMadeProgress` runs (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:289-293,701-771`). This is the intended shape, but its observable retry path does not work in the added regression test.

The following command was run twice, once as part of the whole focused class and once for the single test:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES -only-testing:NearWireViewerTests/ViewerFlowControlTests/testDownlinkMailboxBackpressureRetriesWithoutSequenceGapOrDisconnect
```

Both runs failed. After capacity was restored and `.sendCompleted` supplied the mailbox-progress signal, the event queue did not drain within the test deadline (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:314-339`). The test then decoded the previously sent Control frame and failed with `invalidMessageType`. The isolated run executed one test with two assertions/errors and exited 65.

This leaves the normative “Downlink mailbox rejects a frame” scenario unproved and reproduces the stalled-retry aspect of Round 1 finding I1-004. Static inspection indicates tentative sequence and queue state remain atomic; the defect is in progress/wake delivery after rejection.

**Required fix:** determine why mailbox progress fails to service the blocked queue, repair the one-shot wake/progress transition without immediate polling, and make the focused regression pass. Assert the same queue entry, sequence zero, unchanged fairness/token state before retry, one admitted frame after capacity returns, and no disconnect. Add the required earlier-frame-success/later-frame-rejection and terminal-after-rejection cases.

### NW-MFC-CT-I2-002 — Medium — Approval mode does not preserve a partial session-frame suffix after App Hello

The Round 1 complete-frame case is fixed, but the neighboring partial-tail state still loses protocol ownership. Before attachment, the decoder is limited to one completed frame. Decoding App Hello changes the core to `awaitingConsumer` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:549,568-578`). If the same callback ends with only a prefix of the next session frame, decoder progress is `needsMoreBytes`, not `pausedOnCompleteFrame`. The core therefore does not claim a receive-pause token and applies ordinary resume behavior (`ViewerAdmission.swift:609-630`).

Under approval admission, attachment has not happened yet. A later callback that completes the frame reaches `handleReceivedBytes` while state is still `awaitingConsumer`; that state is rejected and the connection is cancelled (`ViewerAdmission.swift:530-536`). Automatic admission usually attaches reentrantly inside the Hello callback and masks this branch. The new approval test covers Hello plus one **complete** acceptance frame only (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:197-254`).

This violates continuous same-core decoder ownership and makes valid packet fragmentation dependent on how long a human takes to approve.

**Required fix:** while `awaitingConsumer`, retain and charge both complete and partial post-Hello suffixes under one bounded pause owner, or otherwise prevent receive rearm until approval attaches or rejects the session. Add approval tests for Hello plus a policy-frame prefix, later completion after acceptance, rejection/timeout/shutdown, exact decoder bytes, exactly one token resolution, no intervening callback, and one terminal outcome.

### NW-MFC-CT-I2-003 — Medium — Receiver-local TTL is rounded to milliseconds and can deliver an already-expired Event

`WireEventRecord.receiverEvent` correctly creates an exact nanosecond receiver deadline. `admitIncoming`, however, converts `remainingTTLNanoseconds` to `EventTTL` using integer division and `max(1, ...)` before placing the value in `BoundedEventQueue` (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:510-520`). The queue then governs later expiry using this rounded millisecond value.

For a remaining TTL below one millisecond, the queue deadline is extended to one millisecond. If uplink delivery is delayed by an exhausted token bucket or an in-flight sink handoff, the event can be dequeued after its exact `WireReceivedEvent.deadlineNanoseconds` but before the rounded queue deadline. For larger non-integral millisecond values the deadline is shortened instead. No delivery-time exact-deadline check compensates for either difference.

This conflicts with the requirement that receiver-local TTL use the frame-completion receipt sample and that expired input never reach the sink (`specs/viewer-multidevice-flow-control/spec.md:163,216`).

**Required fix:** preserve the exact receiver-local nanosecond deadline in queue scheduling, or perform an atomic exact-deadline eligibility check before handoff while retaining correct sequence/drop accounting. Add sub-millisecond, non-integral-millisecond, equality-boundary, blocked-sink/token, and next-contiguous-sequence tests.

### NW-MFC-CT-I2-004 — Medium — Local drop causes and telemetry are collapsed into `overflowDropped`

The capability requires separate saturating local enqueue, dequeue, overflow, expiry, route-drop, and keep-latest coalescing counters, and requires coalescing telemetry to identify replacements. The implementation keeps only one aggregate `droppedEvents` counter and one aggregate `pendingLocalDropSummary` value. Every local cause reaches `addDrops(Int)`, and every wire summary encodes the aggregate solely as `overflowDropped`, with `expired` and `coalesced` fixed to zero (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:851-870`).

The new keep-latest test currently codifies the wrong category by expecting a coalesced replacement to arrive as `overflowDropped` (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:388-443`). Expiry and overflow would be indistinguishable for the remote peer and in per-session diagnostics.

**Required fix:** retain saturating typed counters and a bounded typed pending-summary aggregate, encode each cause in its protocol field, and expose the required closed telemetry without Event content. Correct the keep-latest oracle and add mixed overflow/expiry/coalescing, saturation, mailbox-blocked aggregation, and terminal cleanup tests.

### NW-MFC-CT-I2-005 — Medium — The deterministic requirement-to-evidence matrix remains incomplete

The Viewer suite now has 17 tests and covers useful remediations: approval plus a complete coalesced frame, a 70-message continuation, mailbox retry intent, blocked sink isolation, summary in-flight coalescing, zero-rate no-poll behavior, bounded preference blobs, live nickname preservation, dynamic policy timeout, recent-row cap/expiry, closed snapshot diagnostics, and basic bidirectional exchange.

It still does not provide the matrix explicitly required by Tasks 5.1–5.5 (`openspec/changes/viewer-multidevice-flow-control/tasks.md:24-30`). Material omissions include:

- pure and barrier-controlled mixed provisional/negotiating/active/disconnecting 16-owner states through exact cleanup;
- approval duplicate behavior, attachment rollback/double-attach, reconnect-at-expiry, and terminal/shutdown winner orders;
- policy deadline-minus-one/equality/plus-one continuation arbitration, lower/escalated/indistinguishable acceptance, initial local-admission delay, and exact close counts;
- partial-tail attachment and recorded-timeout cleanup, immediate-driver resume races, total retained-byte accounting, split/coalesced receipt equivalence, and stale-token zero residue;
- inbound invalid-route/epoch/sequence zero commit, exact TTL plus sequence, priority overflow, count/byte/single-event limits, maximum frame and 256-record atomicity, ingress/token/system storms, and telemetry saturation;
- earlier-success/later-mailbox-rejection, terminal queue clearing, missed-batch nonreplay, exact task ownership, and 1/4/8/16-session slow/full/invalid-device isolation;
- presentation/SwiftUI behavior, complete closed diagnostic surfaces, affected Core/SDK suites, packaging/privacy inspection, and requirement-to-evidence mapping.

The tests use an injected manual scheduler for many new cases, which is an improvement, but asynchronous settling still relies on a `Date`/`RunLoop` polling helper (`ViewerFlowControlTests.swift:853-861`) instead of explicit barriers. The active task list remains unchecked from 2.1 onward, and the evidence directory contains no successful implementation validation or spec-to-evidence audit.

**Required fix:** complete the proportional matrix already enumerated in Tasks 5.1–5.5, replace timing-sensitive polling at race boundaries with controllable barriers/driver state, save exact successful command output under `evidence`, and only then mark task checkboxes complete.

## Validation Results

- Focused Viewer class command: built successfully, then failed. **17 tests executed; 2 failures in one test; exit 65.** The failing test was `testDownlinkMailboxBackpressureRetriesWithoutSequenceGapOrDisconnect`.
- The same mailbox-retry test run alone failed identically: **1 test executed; 2 failures; exit 65.**
- `openspec validate viewer-multidevice-flow-control --strict`: the change validated successfully. The CLI subsequently logged a non-gating PostHog DNS flush error because external telemetry was unavailable.
- `git diff --check`: passed.
- `swift test --filter 'WireFrameTests|SecureByteChannelTests'`: could not start because the managed environment denied writes to `/Users/tangent/.cache/clang/ModuleCache`; this is an environment limitation, not a test pass or product failure.
- `xcodebuild test -workspace NearWire.xcworkspace -scheme NearWireCore ...`: could not run because the `NearWireCore` scheme is not configured for a test action. No Core suite pass is claimed.

## Verified Strengths

- Core resumable decoding and the secure receive-pause token retain bounded ordered input and prevent driver rearm for the covered complete-frame path.
- Recorded policy timeout now has an explicit terminal-without-resume disposition.
- Inbound frame admission plans sender tokens, sequence, and queue state on copies and commits them only after all records validate.
- Downlink encoding uses tentative queue, batch-scheduler, token-bucket, and sequence copies and commits only after mailbox admission.
- Session queues have concrete 5,000-event/16-MiB limits and are cleared on terminal paths.
- Session service is consolidated under one replaceable absolute-deadline wake, and uplink consumer work is moved off the protocol executor.
- Manager slot release waits for exact handle cleanup; recent rows are bounded and one manager wake owns expiry.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 5 — 0 High, 5 Medium, 0 Low.**

The central ownership and atomic-commit architecture is substantially stronger than Round 1, and five of the seven prior findings are resolved at implementation level. Completion is still blocked by the reproducible mailbox-retry failure, partial-tail approval handling, exact receiver TTL semantics, typed drop telemetry, and the incomplete deterministic evidence matrix.
