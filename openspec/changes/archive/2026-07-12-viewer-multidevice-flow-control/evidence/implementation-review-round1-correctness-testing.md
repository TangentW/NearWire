# Implementation Review Round 1 — Correctness and Testing

Date: 2026-07-13

## Scope

Reviewed the complete current uncommitted implementation for `viewer-multidevice-flow-control` against its proposal, design, capability specification, and tasks. I inspected the Core decoder/channel changes, Viewer admission continuation, session and manager implementations, application-model integration, UI-facing snapshots, new Core tests, Viewer flow-control tests, documentation, and available evidence. No production or test source was modified; this report is the only added file.

Severity meanings:

- **High:** data/protocol corruption, an unsafe ownership design, or a release-blocking defect without a bounded workaround.
- **Medium:** an actionable requirement violation, race, stalled progress path, or missing safety evidence that must be fixed before the change can complete.
- **Low:** a bounded correctness or presentation defect that does not invalidate the central architecture.

## Findings

### NW-MFC-CT-I1-001 — Medium — Approval-mode coalesced input loses its only continuation and can never reach the attached session

When App Hello is followed by another frame in the same receive callback, the admission decoder stops after its one-frame pre-session quantum and claims the receive-pause token. In approval mode, the core is still `awaitingConsumer`. The scheduled continuation therefore fails the `sessionAttached` guard and resolves the token with cancellation instead of retaining ownership for the later approval (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:594-607`).

Later approval calls `attachSession`, which only installs the receiver and changes state; it does not reschedule the retained decoder suffix or resume receive (`ViewerAdmission.swift:366-373`). The retained frame remains in `WireFrameDecoder`, the channel was deliberately not rearmed, and session startup waits for a policy acceptance that may already be stranded. The connection eventually times out even though the handoff succeeded.

This violates synchronous same-core attachment, preservation of coalesced post-Hello input, and optional approval behavior. Existing approval tests do not combine delayed approval with coalesced session input.

**Required fix:** keep one bounded paused suffix/token while `awaitingConsumer`, and have successful attachment schedule its continuation before returning. Rejection, admission timeout, shutdown, or terminal must cancel the token and clear the suffix exactly once. Add both approval winner orders and Hello-plus-next-frame tests with exact token, decoder-byte, receive-request, and terminal counts.

### NW-MFC-CT-I1-002 — Medium — Recorded policy timeout still resumes receive on `needsMoreBytes`

`ViewerDeviceSession.decoderDidProgress` correctly detects `deadlineElapsed` plus `needsMoreBytes`/`drained` and calls `fail(.policyTimeout)` (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:233-245`). However, `fail` only enqueues `core.closeSession()` after updating session state (`ViewerMultiDeviceSession.swift:625-636`). Control then returns to the admission core, whose generic `.needsMoreBytes`/`.drained` branch immediately calls `resolveReceivePause(resume: true)` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:554-565,584-619`).

The pause token may therefore rearm one receive before the asynchronously queued close wins. That is the exact composed branch the final artifact remediation says must clear partial bytes, resolve without rearm, and close once. The session callback cannot communicate the required no-resume disposition because `decoderDidProgress` returns `Void`.

**Required fix:** make decoder progress handling return an explicit owner decision such as resume, continue, or terminal-no-resume, or have the core synchronously observe its terminal transition before resolving the token. Add the required recorded-timeout partial/drained test with zero rearm, zero later callback, released decoder bytes, one token resolution, unchanged effective policy, and exact close count in both timeout/continuation orders.

### NW-MFC-CT-I1-003 — Medium — Policy timeout sleeps ten seconds after admission instead of until the already-started deadline

Initial negotiation captures `started` before acknowledgement encoding and mailbox admission, and dynamic offers likewise receive a pre-encoding start sample (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:175-191,387-405`). The timeout task is created only after both local admissions, but always sleeps the full ten seconds (`ViewerMultiDeviceSession.swift:406-415`).

Any time spent encoding or waiting for synchronous mailbox admission is therefore added to the normative non-resetting ten-second deadline. The stored `policyDeadline` is correct, but no callback runs at that deadline; a silent peer can remain negotiating/update-pending late until the post-admission sleep completes. No deterministic deadline-start or delayed-admission test exists.

**Required fix:** after successful admission, compute an overflow-safe remaining duration from the unchanged deadline and current injected monotonic time, or time out immediately if it has elapsed. Test delayed acknowledgement/offer admission, deadline-minus-one, equality, and deadline-plus-one without wall-clock sleeps.

### NW-MFC-CT-I1-004 — Medium — Downlink mailbox rejection closes the session instead of preserving an atomic retry

`drainDownlink` correctly prepares queue, scheduler, bucket, and sequence copies, but any `admitSessionSend` error falls into the outer catch and closes the session as `localAdmissionFailure` (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:543-613`). The original queue and sequence remain uncommitted, but terminal cleanup then clears the queue, so the same tentative sequence range is never retried.

The specification requires transient mailbox rejection to commit no sequence, queue removal, fairness credit, token, or dequeue telemetry and to retry the same range exactly once after progress. The implementation also calls `addDrops` for planned expiries before mailbox ownership is known (`ViewerMultiDeviceSession.swift:557`), so telemetry can mutate even when the corresponding planned queue state never commits.

**Required fix:** distinguish transient capacity rejection from terminal/encoding failure, preserve the original queue and tentative sequence on rejection, wait for mailbox progress without an immediate loop, and retry the identical frame/range. Commit pre-admission expiry state in a separate atomic step or defer its telemetry consistently. Add rejection/retry, earlier-frame-success/later-frame-rejection, no-gap/no-duplicate, exact queue/fairness/token/telemetry, and terminal-after-rejection tests.

### NW-MFC-CT-I1-005 — Medium — Queue service is neither complete nor deadline-driven

Uplink delivery drains at most 128 records once during inbound admission. If the delivery bucket has no token or more queued records remain, the method returns without scheduling a token or TTL wake (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:463-527`). There is no uplink service task, so queued Events can remain forever when the App stops sending, and expired entries are not serviced or summarized at their exact deadline.

Downlink uses a 500 ms batch wake, but when an effective rate is zero or no token is available it repeatedly advances the batch scheduler and reschedules another 500 ms wake while the queue remains nonempty (`ViewerMultiDeviceSession.swift:529-565`). This is polling blocked work rather than scheduling the next relevant token/TTL/mailbox deadline, and it can continue indefinitely for a paused direction.

**Required fix:** implement one replaceable per-session wake covering uplink tokens, downlink tokens/batch deadline, both queue TTLs, policy deadline, and mailbox progress. Service only the finite quantum, schedule the exact next eligible boundary, and own no task when no progress deadline exists. Add fake-clock tests proving eventual uplink delivery without new network input, exact TTL expiry, zero-rate no-poll behavior, missed-interval nonreplay, and one task plus one coalesced successor.

### NW-MFC-CT-I1-006 — Medium — The required deterministic requirement-to-test matrix is largely absent

`ViewerFlowControlTests` contains six flow-control tests. They cover preference basics, nickname validation, sixteen automatically negotiating sessions, one conservative initial policy, tuple variants, and one happy-path bidirectional exchange (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:8-283`). They use live scheduling and a polling helper based on `Date`, `RunLoop`, and five-millisecond waits (`ViewerFlowControlTests.swift:302-311`) rather than injected monotonic time and barriers.

There is no Viewer test evidence for:

- pure/mixed provisional, negotiating, active, and disconnecting capacity through cleanup;
- 64-row churn, deterministic eviction, exact 30-second expiry, reconnect boundary, or one expiry owner;
- initial/dynamic deadline winners, lower/latest attribution, zero, escalation, timeout deferral, partial-tail no-resume, physical terminal, or shutdown;
- inbound TTL/overflow/sequence combinations and invalid-frame zero commit;
- queue count/byte/single-event bounds, keep-latest, mailbox rejection/retry, fairness/token/telemetry atomicity, terminal drops, or shutdown clearing;
- service quanta, equal-sample split/coalesced integration, more than 64 frames, 33–128 system messages, sender/system storms, or cross-session progress;
- 1/4/8/16 active integrations, slow/full device isolation, pause/refresh preservation, exact cleanup, presentation behavior, or diagnostic/reflection safety.

The new Core tests validate three decoder cases and three basic pause-token cases, but not the cross-layer Viewer state machine required by Tasks 5.1–5.3. All apply and evidence tasks remain unchecked, and there is no implementation validation or requirement-to-evidence mapping under the change evidence directory (`openspec/changes/viewer-multidevice-flow-control/tasks.md:8-35`).

**Required fix:** implement the deterministic test matrix already enumerated in Tasks 5.1–5.5, using injected scheduler state and explicit barriers rather than sleeps/polling. Save exact successful Core, Viewer, SDK, packaging, privacy, and repository-gate results before marking any task complete.

### NW-MFC-CT-I1-007 — Low — Editing a live nickname is overwritten by the next session snapshot

The manager updates its stored live snapshot when a nickname is edited (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSessionManager.swift:178-198`). The session itself stores only immutable `nicknameAtAttachment` and republishes that old value on every later policy, queue, throughput, or terminal snapshot (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:75-76,131-136,648-678`). Consequently, a successful live edit can visually revert on the next ordinary session update even though the preference was persisted.

**Required fix:** make nickname part of serialized mutable session presentation state or have the manager overlay the authoritative preference on every incoming snapshot. Add live-edit-followed-by-policy/telemetry/terminal snapshot tests and recent-row continuity coverage.

## Validation Observations

- `xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES` built the implementation and all six new flow-control tests passed. The overall run failed only in the existing entitlement inspection because code signing was explicitly disabled: 62 tests executed, 2 assertions failed, and 1 test was skipped.
- The broader `platform=macOS` invocation attempted both arm64 and x86_64 and failed dependency resolution for the Viewer module on x86_64. No clean required Viewer scheme result has been saved as change evidence.
- Direct `swift test` could not run in the managed environment because SwiftPM attempted an additional sandbox/module-cache operation. This environment limitation does not replace the required Core suite evidence.
- `git diff --check` passes after adding this report.

## Verified Strengths

- The Core decoder preserves a paused whole frame and suffix in wire order and reports distinct paused, partial, and drained progress.
- The secure-channel pause token is idempotent, generation-bound, prevents eager receive rearm, and invalidates on terminal state.
- Inbound validation uses planned sequence, queue, and sender-contract copies, so a malformed later record does not partially commit the frame.
- Downlink preparation uses tentative sequence, queue, scheduler, and token copies and commits them only after mailbox ownership; the remaining defect is rejection policy and retry.
- Session count and recent-row collections have concrete bounds, deterministic recent eviction, and one expiry task in the implementation.
- Requested/effective policy values, exact tuple correlation, connection-bound downlink targeting, bounded preferences, and latest-only MainActor snapshot coalescing are present.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 7 — 0 High, 6 Medium, and 1 Low.**

The implementation establishes the intended ownership primitives, but several required winner/progress paths are incorrect and the deterministic evidence matrix is far from complete. Fix the six Medium findings first, add the missing test/evidence coverage, then rerun a fresh independent correctness/testing review.
