# Implementation Review Round 2: Security, Performance, and Documentation

## Scope and Verdict

This independent round re-read `AGENTS.md`, the active proposal, design, capability specification, tasks, all Round 1 implementation reports, the current Core and Viewer diff, session/admission/preferences/manager/UI implementation, focused tests, operator documentation, project packaging, and the built privacy manifest. No production, test, specification, or task source was modified; this report is the only file added by this review.

Round 1 remediation materially improved the implementation. Drop summaries now retain one in-flight frame plus one saturating aggregate and reserve the Control allowance; active input configuration is overflow-checked against the negotiated maximum frame and receive chunks; persisted preference input is rejected above 2 MiB before JSON decoding; policy/TTL/token work uses one replaceable service wake; and uplink callbacks no longer execute on the protocol executor.

Four actionable findings remain. The most important is that a blocked uplink consumer can retain a complete handed-off Event batch and dispatch worker after terminal cleanup, and repeated reconnects can accumulate those orphaned resources without a global lifetime bound.

**Exact unresolved actionable finding count: 4 — 0 High, 3 Medium, and 1 Low.**

**Approval withheld.** Resolve the findings below, complete the required deterministic evidence matrix, and obtain a fresh review round.

## Round 1 Finding Disposition

| Round 1 finding | Round 2 status |
| --- | --- |
| `NW-MFC-IMPL-SPD-002` drop-summary coalescing and Control reservation | Resolved in implementation and focused coverage. |
| `NW-MFC-IMPL-SPD-003` sink executed inline on protocol executor | Protocol isolation resolved; terminal ownership remains unresolved as Round 2 finding 001. |
| `NW-MFC-IMPL-SPD-004` unbounded preference decode | Resolved by the pre-decode 2 MiB check and oversized-blob test. |
| `NW-MFC-IMPL-SPD-005` incomplete/failing validation evidence | Unresolved as Round 2 finding 003. |
| `NW-MFC-IMPL-SPD-006` diagnostic/reflection guard | Partially remediated for `ViewerSessionSnapshot`; unresolved for other new models as Round 2 finding 004. |

## Findings

### NW-MFC-IMPL-SPD-R2-001 — Medium — Terminal cancellation cannot release a blocked uplink handoff batch

**Evidence**

- `deliverUplink` removes up to 128 Events and 16 MiB from the bounded queue only after passing a copied `[WireReceivedEvent]` to `ViewerUplinkHandoff.offer` (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:534-573`).
- `offer` captures the complete immutable array in a dispatch block, then calls an arbitrary synchronous sink. `cancel()` only sets a Boolean; it cannot clear the captured array, cancel the currently executing sink, or join the worker (`ViewerMultiDeviceSession.swift:926-973`).
- Session failure and transport-terminal paths call `uplinkHandoff.cancel()` and continue cleanup without waiting for or taking ownership back from that block (`ViewerMultiDeviceSession.swift:789-811`).
- The blocked-sink test proves that protocol Control can progress, but releases the semaphore before shutdown. It does not exercise terminal cleanup, retained Event release, repeated reconnect churn, or another session after orphaning a permanently blocked sink (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:343-386`).

**Impact**

A slow consumer no longer blocks the connection core, which is good, but a consumer that never returns retains peer-originated Event content, the whole not-yet-consumed batch, and a dispatch worker after the connection slot is released. Repeated connect, deliver, block, disconnect cycles can create more orphaned handoffs than the 16 live-session limit, so process memory and execution ownership are not globally bounded over time. This contradicts memory-only terminal clearing and weakens the documentation claim that a slow device cannot affect another session.

**Required remediation**

Define a cancellable, ownership-explicit sink contract whose outstanding storage is mutable and globally/per-manager bounded. Terminal cleanup must synchronously detach and clear all not-yet-consumed Events; it must either join a bounded consumer operation or define the currently delivered value as transferred consumer ownership without retaining the rest of the batch. Add barrier tests for terminal-before-sink-entry, terminal while the first Event is blocked, repeated reconnect churn, exact retained batch/task counts, and independent-session progress.

### NW-MFC-IMPL-SPD-R2-002 — Medium — Required oldest-wait telemetry and operator bounds are absent

**Evidence**

- The normative snapshot and workspace requirements require current queue count, bytes, and oldest wait (`specs/viewer-multidevice-flow-control/spec.md:294,318`), and the design repeats that contract (`design.md:132,140`).
- `ViewerSessionSnapshot` has queue count and byte fields but no uplink/downlink oldest-wait value. Publication reads only direct queue count/bytes (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:24-46,814-842`).
- The UI displays only count and bytes for each queue (`Viewer/NearWireViewer/UI/ViewerRootView.swift:233-245`). The operator guide accurately describes the implemented subset but therefore also omits oldest wait (`Documentation/Viewer-MultiDevice-Flow-Control.md:51-55`).
- Task 5.4 additionally requires operator documentation for work bounds and failure categories. The guide says only that business work is bounded; it does not document the 19 MiB total-input maximum, 64-frame/512-record/32-system/128-publication quanta, 64-per-second/128-burst system limit, or the closed terminal categories (`Documentation/Viewer-MultiDevice-Flow-Control.md:27-41`; `design.md:112-114`).

**Impact**

Operators cannot distinguish a small newly queued workload from an equally small queue that has stalled for a long time, and the implementation/documentation does not satisfy the agreed operational telemetry contract. Missing hard-bound and failure-category documentation also makes memory/abuse behavior difficult to review and operate consistently.

**Required remediation**

Publish bounded oldest-wait values for both queues, clear them in recent/terminal presentation, render them with deterministic accessibility coverage, and document the actual input, callback, record, system, publication, mailbox, queue, and terminal-category bounds. Keep the guide aligned with the values enforced in code.

### NW-MFC-IMPL-SPD-R2-003 — Medium — Required implementation, packaging, privacy, and abuse evidence remains incomplete and the focused suite fails

**Evidence**

- Tasks 2.1 through 5.5 remain unchecked, and the evidence directory still has no consolidated implementation validation, requirement-to-evidence matrix, package/structure output, or saved built-privacy inspection (`openspec/changes/viewer-multidevice-flow-control/tasks.md:8-30`).
- The expanded Viewer file contains 17 focused tests, but still omits much of Tasks 5.1-5.4, including total-input configuration boundaries, terminal handoff retention, exact queue count/byte/single-Event boundaries, telemetry saturation, multi-session slow/full isolation, 1/4/8/16 active integration, shutdown ownership, and complete presentation/diagnostic coverage.
- This review ran:

  ```text
  xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-impl-review-round2-spd-current CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests
  ```

  The build succeeded but the command exited 65. `testDownlinkMailboxBackpressureRetriesWithoutSequenceGapOrDisconnect` failed: its wait assertion at line 869 timed out and line 336 decoded a non-Event message as `WireEventPayload`.
- Strict OpenSpec validation and `git diff --check` pass. The built app's `PrivacyInfo.xcprivacy` was present and currently declares UserDefaults reason `CA92.1`, linked Device ID for App functionality, tracking false, and no tracking domains. This supports the guide's privacy rationale, but the required exact result is not yet saved as task evidence.

**Impact**

The change cannot meet the repository completion gate from a failing focused suite and a narrow subset of the required abuse/lifecycle matrix. Correct-looking local bounds are not yet backed by executable evidence across Core, Viewer, SDK, packaging, privacy, and multi-session cleanup.

**Required remediation**

Fix and stabilize the bidirectional test, add the remaining proportional deterministic tests from Tasks 5.1-5.4, run every Task 5.5 command in its supported environment, save exact outputs under `evidence`, and mark each task only after its stated proof exists.

### NW-MFC-IMPL-SPD-R2-004 — Low — Diagnostic reflection protection covers only the aggregate snapshot

**Evidence**

- `ViewerSessionSnapshot` now has safe custom description, debug description, and reflection exposing only state and closed terminal category (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:51-70`).
- Other new diagnostic-capable values retain synthesized reflection. In particular, `ViewerLogicalRoute` directly stores installation and Bundle identifiers, while `ViewerRatePolicy` stores rate values (`Viewer/NearWireViewer/Session/ViewerDevicePreferences.swift:5-31`). Direct `Mirror(reflecting:)` on those values exposes fields prohibited by the diagnostic requirement.
- The new diagnostic test reflects only `ViewerSessionSnapshot`; because that type supplies a custom mirror, it never exercises direct route, policy, manager-row, error, presentation, or interpolation surfaces (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:600-643`).

**Impact**

No production logger or current runtime disclosure was found. However, later debug interpolation, reflection-based tooling, assertion output, or telemetry adapters can expose unauthenticated identifiers and rate values without failing CI, contrary to the closed-code diagnostic contract.

**Required remediation**

Enumerate every new value that may reach diagnostic, reflection, presentation-error, assertion, or logging code. Add sentinel tests for direct descriptions/reflections and either provide closed custom surfaces or mechanically prohibit unsafe use. Include identifiers, nicknames, rates, queue values, epochs, Event values, raw bytes, peer text, and underlying errors.

## Verified Security and Performance Properties

- Drop-summary admission uses the same one-slot/64 KiB Control reservation as business Event sends, tracks one completion-tagged summary in flight, and retains later loss only in one saturating counter (`ViewerMultiDeviceSession.swift:851-891`; `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:420-451,524-527`).
- The total session-input budget is overflow-checked as maximum negotiated Event frame plus two receive chunks and capped at 19 MiB before session activation; callback bytes plus decoder-retained bytes are charged against that one limit (`ViewerMultiDeviceSession.swift:167-177`; `ViewerAdmission.swift:539-565`).
- Preference persistence rejects raw data above 2 MiB before decoding, filters invalid fields, caps both maps at 256, uses deterministic eviction, and rewrites repaired state (`Viewer/NearWireViewer/Session/ViewerDevicePreferences.swift:40-49,124-173`).
- One generation-checked session wake covers policy, token, batch, and TTL work; zero-rate queues do not install a 500 ms polling wake. The manager separately owns one replaceable recent-row expiry wake.
- Tuple correlation remains explicitly unauthenticated, duplicate exact routes do not replace a live owner, downlink stays connection/epoch-bound, and recent rows omit Event/epoch/endpoint/TLS/wire state.
- No new logger, analytics, clipboard, export, database, third-party runtime dependency, nested package manifest, or entitlement was added. Event content is absent from Viewer UI and persisted preferences.
- The built privacy manifest matches the documented UserDefaults and linked Device ID/App-functionality rationale and has tracking disabled.

## Required Review Gate

Resolve `NW-MFC-IMPL-SPD-R2-001` through `NW-MFC-IMPL-SPD-R2-004`, rerun affected Core/Viewer/SDK/packaging/privacy validation, save the exact evidence, and request a fresh independent security/performance/documentation review. Do not approve this dimension while any finding remains unresolved.
