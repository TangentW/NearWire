# Implementation Review Round 1 — Architecture and API

Date: 2026-07-13

## Scope

Reviewed the complete current uncommitted implementation for `viewer-multidevice-flow-control` against `AGENTS.md`, the active proposal, design, normative specification, and tasks. The review inspected the changed Core transport/framing code, Viewer admission/session/manager/application/UI code, Xcode project, new Core and Viewer tests, and documentation. No production or test source was modified; this report is the only added file.

Severity meanings:

- **High**: an ownership or API defect that invalidates the architecture boundary or can couple/corrupt multiple sessions.
- **Medium**: a concrete protocol, resource, lifecycle, or scheduling defect that violates a normative requirement and must be fixed before completion.
- **Low**: a currently unexercised internal API ambiguity that can violate the contract if reused.

## Findings

### 1. Medium — Recorded policy timeout still resumes receive for partial/drained decoder progress

`ViewerDeviceSession.decoderDidProgress` correctly detects `deadlineElapsed` followed by `needsMoreBytes` or `drained` and calls `fail(.policyTimeout)` (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:233-245`). That failure only schedules `core.closeSession()` asynchronously on the same core queue (`ViewerMultiDeviceSession.swift:625-635`). Control then returns to `ViewerAdmissionConnectionCore.applyDecoderProgress`, which unconditionally resolves the pause token with `resume: true` for both progress values (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:554-562,568-590`). The queued close runs later.

The channel can therefore rearm one receive after the recorded timeout has selected terminal state. This directly violates the specified `deadlineElapsed + partial/drained` exception, which must clear decoder/token state and never resume. It also defeats the purpose of the cross-layer pause token: the session decides terminal, but the core has no synchronous disposition with which to retain/cancel token ownership.

**Required fix:** make decoder-progress notification return a core-consumable disposition such as ordinary-resume, retain-paused, or terminal-no-resume, or synchronously expose receiver terminal state before `applyDecoderProgress`. When the recorded timeout closes, the core must clear decoder state and cancel the token in that same operation, without calling `resume()`. Add a controllable-driver test proving no receive request or callback exists after timeout reaches partial-only or drained input.

### 2. Medium — Session scheduling does not implement the one earliest-deadline wake and can either stall or poll

The design requires one replaceable per-session wake covering policy, rate-token, batch, TTL, and cleanup deadlines. The implementation instead owns independent `policyTimeoutTask` and `downlinkWake` tasks (`ViewerMultiDeviceSession.swift:88-101,387-415,529-540`), so both may exist concurrently. There is no corresponding uplink token/TTL wake at all: `deliverUplink` simply returns when no token is available, leaving queued Events undelivered until unrelated later ingress happens (`ViewerMultiDeviceSession.swift:504-527`). Queue expiry likewise occurs only when another dequeue/service path happens.

The downlink path has the opposite problem. At zero or temporarily exhausted rate it advances the 500 ms batch scheduler and schedules another batch wake while the queue remains nonempty (`ViewerMultiDeviceSession.swift:543-565,609-610`), creating periodic polling instead of waiting for the next meaningful token/policy boundary. This breaks the no-idle/retry-loop power contract and gives each session more scheduled owners than specified.

**Required fix:** replace the separate task fields with one session wake owner that computes the earliest policy, token, batch, TTL, or cleanup boundary. It must schedule uplink delivery/expiry when tokens are unavailable, avoid periodic work at zero rate until policy changes, retain at most one task plus the specified coalesced successor, and keep receive continuation ownership separate. Add exact task-count and progress tests for zero rate, token exhaustion, TTL-only work, simultaneous policy/batch deadlines, and shutdown.

### 3. Medium — Business mailbox backpressure closes the session instead of preserving an atomic retry

`drainDownlink` correctly performs queue, scheduler, bucket, and sequence work on value copies. But if `admitSessionSend` rejects the complete frame because the bounded mailbox is full, the catch block converts that ordinary capacity condition into `.localAdmissionFailure` and closes the session (`ViewerMultiDeviceSession.swift:543-613`). Terminal cleanup then clears the still-owned queue.

The normative contract requires a rejected business frame to commit no sequence, queue removal, fairness, token, or telemetry state and later retry the same range when mailbox progress occurs. A slow/full device should be isolated by bounded waiting, not disconnected merely because Event capacity is temporarily unavailable. `sessionMailboxMadeProgress` already provides the correct retry signal, but the failure path never leaves the session alive to use it (`ViewerMultiDeviceSession.swift:252-257`).

**Required fix:** distinguish bounded mailbox capacity rejection from encoding/protocol/local-configuration failure. On capacity rejection, keep every planned value uncommitted, mark the downlink pump blocked without immediate retry, and wait for send-capacity progress before attempting the same queue entries and next sequence. Close only for genuine terminal/configuration failure. Add exact mailbox rejection/retry tests, including an earlier admitted frame followed by a rejected frame.

### 4. Medium — Policy timeout is scheduled one full interval after admission rather than at the already-computed deadline

`beginPolicyOffer` correctly computes `policyDeadline = startedAt + 10 seconds`, where `startedAt` is sampled before encoding and mailbox admission (`ViewerMultiDeviceSession.swift:175-191,387-405`). It then creates a task that sleeps a fresh full 10 seconds beginning only after encoding and admission have completed (`ViewerMultiDeviceSession.swift:406-415`). Any local preparation/admission time is therefore added to the actual timeout firing time, despite the requirement that it count against the same non-resetting deadline.

Acceptance samples at or after the stored deadline are rejected, so the session can remain stuck in negotiating/update-pending state after its deadline until the late task eventually wakes. This also weakens deterministic timeout-versus-suffix arbitration.

**Required fix:** after successful admission, schedule only `max(0, deadline - scheduler.now())`, preserving the pre-encoding start sample and generation. If local work already reached the deadline, enqueue timeout immediately. Add injected-clock tests where encoding/admission consumes part or all of the 10-second interval.

### 5. Medium — The required active-ingress cross-limit validation is absent

`ViewerSessionIngressLimits` validates only that the frame-turn count is positive and total retained bytes are between 1 and 19 MiB (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:54-68`). The channel's `receiveChunkBytes` is exposed through `ViewerAdmissionChannel` but is never read, and `ViewerDeviceSession` always selects the fixed 2 MiB default (`ViewerAdmission.swift:6-45`; `ViewerMultiDeviceSession.swift:67`). No attachment/activation step proves that total input fits the negotiated maximum encoded active frame plus twice the configured receive chunk, nor is `maximumFramesPerTurn` capped at the specified hard maximum.

The live defaults happen to fit, but the internal API accepts other valid Core channel/negotiation configurations that can exceed the chosen Viewer budget. Such a session will close valid input at runtime instead of failing local configuration before active mutation, and the stated 2/19 MiB accounting is not enforced compositionally.

**Required fix:** validate ingress limits synchronously before session attachment/active state using the actual channel receive limit, negotiated frame/Event limits, decoder hard limit, record quantum, and all hard maxima. Reject invalid local composition before admitting acknowledgement/policy frames. Add boundary tests for live defaults, the 16 MiB-plus-overhead frame with two 1 MiB chunks under 19 MiB, overflow, and deliberately incoherent configurations.

### 6. Low — One `WireFrameDecoder` can mix legacy and resumable APIs and reorder retained bytes

`WireFrameDecoder` now stores resumable suffix/frame state in `resumableInput` and `resumableFrame` (`Core/Sources/NearWireTransport/WireFrame.swift:65-97`). `consumeResumable` honors that state, but the existing `consume`/`consumeBounded` methods neither drain it nor reject mixed-mode use (`WireFrame.swift:271-400`). After `consumeResumable` returns `pausedOnCompleteFrame`, a caller can invoke legacy `consume` with later bytes; legacy decoding delivers those later bytes while the earlier resumable frame remains retained, violating ordered-stream ownership. The Core tests cover each mode separately but not this transition.

Current Viewer and SDK call sites choose one mode per decoder, so this is not yet exercised. The SPI type nevertheless exposes an invalid state transition without a guard.

**Required fix:** either unify legacy methods on the resumable implementation or reject legacy consumption while resumable state is nonempty, and symmetrically document/guard all mode transitions. Add a test that attempts to switch modes with a retained complete frame and suffix and proves that later bytes cannot overtake.

## Architecture Checks That Passed

- `ViewerMultiDeviceSessionManager` structurally counts provisional, negotiating, active, and disconnecting entries in the same 16-entry registry and retains disconnecting ownership through exact handle cleanup. Exact-route duplicates are reserved under the manager lock and recent rows remain separately capped at 64.
- Manager registry locks are released before core attachment/operations and before snapshot callbacks. Preference access also occurs outside the manager lock. No actionable manager/core lock inversion was found.
- Same-core handoff installs the session receiver reentrantly before transfer returns, preserves the original secure channel callback/decoder/terminal gate, and retains coalesced post-Hello bytes through the resumable decoder and receive-pause token.
- The secure-channel pause gate is generation-bound and idempotent; nonclaiming consumers preserve eager receive behavior and terminal invalidation prevents stale token resume.
- Core additions remain platform-neutral SPI in `Core`; Viewer policy, lifecycle, persistence, model, and UI remain under `Viewer`. No third-party dependency, nested package manifest, wire-schema change, or supported SDK API was added.
- Snapshot delivery to the main model uses a latest-only coalescer rather than creating one `MainActor` task per session update.

## Validation Observations

- `xcodebuild test` with the ordinary macOS destination failed during the x86_64 Viewer build because the three package module dependencies could not be resolved.
- The arm64-only retry compiled and ran 62 Viewer tests, but `ViewerFlowControlTests.testBidirectionalEventExchangeUsesNegotiatedEpochAndRoutes` failed because no downlink Event arrived within its wait and the test then decoded the prior non-Event frame. The unsigned entitlement assertions also failed as expected with `CODE_SIGNING_ALLOWED=NO`; those packaging failures are separate from this review's architecture findings.
- The new Viewer suite contains only six flow-control tests and does not yet provide the task-plan's mixed four-state registry, timeout/suffix, mailbox retry, coalesced ingress, recent-row churn, scheduler ownership, or 1/4/8/16-device isolation evidence.
- A targeted `swift test` attempt for the Core decoder/channel tests could not start because this sandbox denied SwiftPM's nested `sandbox-exec`; this is an environment limitation, not a claimed pass or product failure.

## Verdict

**Approval withheld.** Same-core ownership, lock ordering, the 16-session registry, and repository boundaries are directionally sound, but the receive-token terminal handoff, session wake model, mailbox backpressure, policy deadline, ingress configuration, and decoder API transition must be corrected and re-reviewed.

**Exact unresolved actionable finding count: 6 — 0 High, 5 Medium, 1 Low.**
