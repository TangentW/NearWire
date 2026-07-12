# Implementation Review Round 3 — Correctness and Testing

Date: 2026-07-13

## Scope

Independently reviewed the current uncommitted `viewer-multidevice-flow-control` implementation after Round 2 remediation. The review re-read the active OpenSpec artifacts, Round 2 correctness report, current Core and Viewer diff, all 20 focused Viewer tests, the new Core exact-deadline queue test, operator documentation, implementation-validation record, privacy inspection, and requirement-to-evidence audit.

This review evaluates coverage proportionately: a requirement does not need a bespoke Viewer test for every phrase when the same primitive or boundary is already exercised by the focused Viewer tests plus the shared Core, SDK, integration, packaging, and full bootstrap suites. No production, test, specification, or task source was modified; this report is the only added file.

## Round 2 Finding Disposition

### `NW-MFC-CT-I2-001` — Resolved — Advisory and authoritative mailbox backpressure retry atomically

`drainDownlink` still prepares queue, batch scheduler, token bucket, output sequence, encoded records, and telemetry on tentative copies. An advisory capacity rejection sets `downlinkMailboxBlocked` and returns without committing those copies. More importantly, an authoritative `SecureTransportError.backpressure` from the actual mailbox ownership boundary is now caught separately and selects the same blocked state instead of terminal failure (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:761-837`). Other admission failures still fail closed.

Mailbox completion clears the blocked flag and schedules the single service wake (`ViewerMultiDeviceSession.swift:339-344`). The focused suite now covers both paths:

- predicate/advisory rejection followed by progress and retry;
- predicate success followed by injected authoritative backpressure, progress, and retry.

Both assert that the session remains active and the retried Event receives sequence zero (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:376-437`). The complete focused suite passed in this review, so the Round 2 stalled-retry observation is no longer reproducible.

### `NW-MFC-CT-I2-002` — Resolved — Approval owns both complete and partial post-Hello input

When App Hello changes the core to `awaitingConsumer`, `applyDecoderProgress` now claims exactly one receive-pause token for every progress state. A complete retained frame preserves its callback receipt; a partial or drained suffix deliberately has no completion receipt yet. In either case the driver cannot rearm while approval is pending (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:613-628`).

After same-core attachment, `continueAttachedInput` distinguishes the two valid branches: it schedules bounded continuation for a complete retained frame, or atomically detaches and resumes the token for a partial/drained suffix so a later callback supplies the completion receipt (`ViewerAdmission.swift:381-402`). Terminal cleanup cancels the token and clears decoder ownership.

The complete-frame and split-frame approval tests both pass. The partial test asserts one claim, no pre-approval resume, one post-attachment resume, successful later completion, no token cancellation, no transport cancellation, and active policy state (`ViewerFlowControlTests.swift:197-316`).

### `NW-MFC-CT-I2-003` — Resolved — Receiver-local TTL preserves its exact nanosecond deadline

`PendingEvent` now optionally carries an explicit monotonic expiration deadline, and `BoundedEventQueue` uses that exact value as its scheduling boundary rather than reconstructing it from millisecond TTL (`Core/Sources/NearWireFlowControl/EventQueueConfiguration.swift:99-134`; `Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:989-1002`). Existing callers retain the original millisecond behavior because the new field defaults to `nil`.

Viewer obtains the overflow-checked receiver-local deadline from `WireEventRecord.receiverEvent` and installs it in the queued Event while retaining the wire TTL model for schema validation (`ViewerMultiDeviceSession.swift:545-579`). Thus a sub-millisecond Event expires at equality on the exact receiver clock, cannot reach a delayed sink, and still consumes its already-validated wire sequence.

The Core boundary test proves presence immediately before 500 microseconds and expiration at equality. The focused Viewer test blocks the first sink handoff, queues a second Event with 500-microsecond remaining TTL, advances exactly to its deadline, and observes one expiry with no second delivery and an active session (`ViewerFlowControlTests.swift:484-544`). Both are included in the recorded passing package/focused results.

### `NW-MFC-CT-I2-004` — Resolved — Local drop telemetry remains typed and saturating

Viewer now keeps separate saturating overflow, expiry, keep-latest coalescing, and connection-owned-clear counts. The same typed aggregate is used for the single pending wire summary, while `localDropSummaryInFlight` still bounds admitted ownership to one frame (`ViewerMultiDeviceSession.swift:87-125,177-186,927-983`).

Wire summaries preserve protocol-supported overflow, expiry, and coalescing fields. Connection-owned clears are visible separately in the local snapshot and are folded into wire overflow only because V1 has no dedicated route/terminal field; the operator documentation states this explicitly. Snapshot/UI values expose the typed totals without Event content.

The keep-latest regression now expects coalesced values of 1 and 9, with overflow and expiry remaining zero, while also proving Control reservation and one-summary-in-flight behavior (`ViewerFlowControlTests.swift:546-607`). Saturating counter primitives and queue causes are covered by the shared Core suite and full bootstrap run.

### `NW-MFC-CT-I2-005` — Resolved proportionately — Validation and requirement evidence are complete

The current evidence is no longer a narrow 20-test claim. `implementation-validation.md` records:

- all 20 focused Viewer flow-control tests passing;
- the formerly intermittent bidirectional test passing 50 of 50 repetitions;
- the selected full Viewer regression suite passing 74 tests with zero failures;
- `swift test` passing 530 tests with zero failures;
- the repository bootstrap passing all 29 gates, including 527 passed/4 skipped iOS tests, 206 Viewer tests, real TLS active-session integration, public-connect TLS integration, Swift Package distribution, CocoaPods verification, and OpenSpec validation;
- strict formatting, diff, and OpenSpec checks passing.

`requirement-to-evidence-audit.md` maps each normative area to implementation and executable/inspection evidence, and `privacy-manifest-inspection.md` records the built manifest. The only deferred signing checks require configured independent signing identities and are explicitly assigned by product-owner decision to the goal-level `release-hardening` change; no signing behavior changed here.

Considering the focused tests together with existing Core queue/token/decoder/channel tests, SDK admission and wire tests, foundation lifecycle/cleanup tests, TLS integration, full Viewer regression, package suite, and bootstrap gates, the current matrix is proportionate to this internal change. I found no correctness requirement whose only support is an unchecked assertion or prose claim.

## Additional Round 3 Checks

### Canonical downlink wall time

Viewer now truncates its locally generated `Date()` to an exact millisecond before constructing a downlink envelope (`ViewerMultiDeviceSession.swift:787,991-997`). This produces a finite value that the canonical wire date formatter can round-trip exactly, while monotonic TTL and rate decisions continue to use the injected monotonic `now`. It does not couple TTL behavior to wall-clock time. The bidirectional regression exercises this path, passed in the focused run, and has a recorded 50-of-50 repetition result.

### Sequence and commit atomicity

Inbound contract tokens, sequence validation, queue admission, and typed-drop results remain planned per whole frame and commit only after every record validates. Downlink queue removal, fairness, batch scheduling, token consumption, sequence allocation, and telemetry remain tentative until the authoritative mailbox admission succeeds. Both advisory and authoritative retry tests observe sequence zero after rejection; no gap or duplicate path was found.

### Bounds, wake ownership, and cleanup

- Each session queue remains bounded to 5,000 Events and 16 MiB with the negotiated single-Event limit.
- Scheduled service is partitioned into two 32-expiration slices, one single-Event consumer handoff, and one at-most-32 Event downlink batch, below the 128-record aggregate default before yielding.
- The session owns one replaceable absolute-deadline wake; recent-row expiry has one separate manager-owned wake. Zero-rate queued business work does not poll.
- Attached input retains the 2 MiB live default and expands only to the proven maximum-frame-plus-two-chunks requirement, capped at 19 MiB.
- Terminal paths cancel service/receive ownership, clear connection-owned queues, preserve closed typed telemetry, and release the manager slot only after exact handle cleanup.

### Test isolation

Focused flow-control cases use isolated `UserDefaults` suites and an injected monotonic scheduler. Some eventual asynchronous assertions still use a short polling helper, but race outcomes themselves are controlled through manual time, pause-token counters, mailbox gates, and sink barriers. The focused suite passed here, and the prior flaky downlink path has a separate 50-iteration stability record. This does not constitute an actionable isolation defect.

## Validation Performed in This Review

Command:

```text
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-r3-correctness-review CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests
```

Result: **passed, exit 0.** All 20 focused tests were selected by the test class. The build emitted only Xcode/XCTest deployment-version and signed-system-binary stripping warnings.

Additional checks:

- `git diff --check`: passed with no output.
- `env DO_NOT_TRACK=1 openspec validate viewer-multidevice-flow-control --strict --no-interactive`: passed; the change is valid.
- A direct filtered `swift test` attempt in this review environment was blocked before execution because nested SwiftPM `sandbox-exec` is not permitted. This is an environment limitation. The current-tree `swift test` 530/0 result and full bootstrap result are already saved in `implementation-validation.md`; no contradictory Core failure was observed.

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

All five Round 2 correctness/testing findings are resolved. The focused regression suite passes, exact TTL and mailbox winner paths have direct executable coverage, typed telemetry and canonical wall time are consistent with the wire contract, and the shared Core/SDK/Viewer/bootstrap evidence proportionately covers the remaining task matrix.
