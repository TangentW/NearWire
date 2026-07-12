# Implementation Review Round 3 — Architecture and API

Date: 2026-07-13

## Scope

Independently reviewed the current uncommitted `viewer-multidevice-flow-control` implementation after Round 2 remediation. The review re-read `AGENTS.md`, the active proposal/design/spec/tasks, the Round 2 architecture report, current Core and Viewer changes, expanded focused tests, operator documentation, implementation validation, privacy inspection, and requirement-to-evidence audit. No production, test, specification, or task source was modified; this report is the only file added by this review.

Per the product-owner direction, this review treats coverage proportionately. It accepts the focused Viewer matrix together with the successful 530-test Swift package suite and repository bootstrap evidence; it does not require a separate test for every phrase in Tasks 5.1–5.4 when the normative risk already has direct implementation and regression evidence.

Severity meanings:

- **High:** an ownership/API defect that can corrupt or couple multiple sessions.
- **Medium:** a concrete lifecycle, ordering, isolation, or resource defect that violates a normative requirement and must be fixed before completion.
- **Low:** a bounded hot-path/API-quality defect that does not currently invalidate protocol ownership but should be corrected before approval.

## Round 2 Remediation Status

| Round 2 finding | Round 3 disposition |
| --- | --- |
| Authoritative mailbox backpressure closes/stalls | **Resolved.** `drainDownlink` treats an authoritative `SecureTransportError.backpressure` as blocked without committing tentative state, and both advisory-false and authoritative-rejection retry tests pass (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:761-837`; `Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:376-437`). |
| Unified wake exceeds aggregate service quantum | **Resolved.** Expiration is capped at 32 per queue, uplink handoff at one Event, and downlink batching at 32, so the composed queue work is at most 97 records per scheduled service turn, below the normative default of 128 (`ViewerMultiDeviceSession.swift:133,243-252,592-635,665-759`). |
| Attached session loses the 2 MiB default input budget | **Resolved.** Session construction now uses `max(default 2 MiB, derived frame + two chunks)` while retaining the 19 MiB hard validation (`ViewerMultiDeviceSession.swift:214-227`). |
| Snapshot-handler reference races outside the manager lock | **Resolved.** Every publication now captures both snapshots and the handler under the manager lock and invokes the captured closure only after unlock (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSessionManager.swift:116-133,181-202,229-308,326-348`). |

## Findings

### 1. Medium — A service wake can advance queue time before an older retained receipt is continued

The decoder correctly preserves the receipt sample of a complete retained suffix and schedules its continuation on the same core queue (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:630-667`). The session's one-shot service task independently enqueues `serviceSession(now: scheduler.now())` onto that queue (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:637-655`). Dispatch FIFO applies after submission, but it does not force the handler's continuation submission to win against a deadline task submitting concurrently from another executor. The specification explicitly accounts for this ordering by allowing the policy-timeout callback to be queued before continuation.

If a queue TTL/batch/token wake at `t1` is submitted first while the decoder owns complete frames sampled at earlier `t0`, `serviceSession(t1)` calls `serviceQueueExpirations` and records `t1` as the observation time of both queues (`ViewerMultiDeviceSession.swift:665-680,735-755`). The later continuation must still process an incoming Event at its preserved `t0` sample (`ViewerMultiDeviceSession.swift:545-589`). `BoundedEventQueue.enqueue` rejects that valid operation because `t0` is lower than its recorded observation time (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:234-240,804-811`). The session normalizes that local clock failure to a protocol violation and closes (`ViewerMultiDeviceSession.swift:290-314`). Related mutable time state can also be rewound or rejected: throughput uses the older second, while token buckets reject a decreasing sample (`ViewerMultiDeviceSession.swift:919-925`; `Core/Sources/NearWireFlowControl/EventRateControl.swift:178-185`).

This makes a valid coalesced Event suffix depend on whether a local service deadline is submitted before its continuation. It conflicts directly with the requirement that continuation delay preserve the frame-completion sample and not change queue, token, TTL, or terminal outcomes. The existing system-burst test proves bounded continuation but does not create a simultaneous queue deadline with retained Event frames.

**Required fix:** serialize time-domain ownership as well as decoder ownership. The simplest shape is to defer nonterminal session service mutation while a retained complete suffix is owned, allow only the specified policy-timeout arbitration to record elapsed state, and schedule the earliest service work after the suffix drains. An alternative multi-clock design must explicitly support retroactive receipt samples without refilling/expiring state out of order. Add one injected-scheduler/barrier regression where a later TTL or batch wake is submitted before an older retained Event continuation and prove identical sequence, queue, token, TTL, throughput, and terminal results in both queue orders.

### 2. Low — Oldest-wait telemetry performs an allocating full-queue scan on every session snapshot

The newly added `BoundedEventQueue.oldestWaitNanoseconds` constructs an array from every stored Event and then computes its minimum (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:223-231`). `ViewerDeviceSession.publishSnapshot` invokes it for both queues (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:878-902`), and snapshot publication occurs after every consumed frame as well as queue, policy, service, and terminal mutations (`ViewerMultiDeviceSession.swift:290-305,346-399,617-623,665-680,820-832`).

The queue is bounded to 5,000 Events, so memory remains finite, but a full slow/blocked session can perform and allocate two 5,000-element scans per incoming frame before the latest-only UI coalescer has any effect. Across 16 sessions this telemetry path can become material protocol-queue CPU and allocation work precisely when queue pressure is highest. The architecture requires telemetry to remain bounded and nonblocking and describes snapshot publication as rate-coalesced; only main-actor delivery is currently coalesced, not this computation.

**Required fix:** maintain oldest enqueue time incrementally or through a stale-node-safe heap/cache, or compute it only in a genuinely rate-coalesced telemetry turn. Preserve keep-latest replacement and arbitrary priority-removal semantics. A proportional queue-level test plus a simple operation-count/benchmark assertion is sufficient; a large new integration matrix is not required.

## Architecture Checks That Passed

- The same connection core, secure callback, resumable decoder, receive-pause token, and terminal gate remain the sole protocol owners across automatic and approval handoff. Complete and partial post-Hello approval suffix tests pass.
- Recorded policy timeout returns a synchronous terminal-without-resume disposition, while ordinary partial input detaches the old token before receive resume.
- Mailbox rejection now preserves sequence, queue, scheduler, fairness, and token copies until authoritative ownership succeeds. Retry remains Event-driven through send-capacity progress rather than polling.
- One generation-checked session wake covers policy, queue expiry, token, and batch work. Zero rates and mailbox blocking do not create recurring polling.
- The 16-entry live registry, 64-row recent registry, exact duplicate-route reservation, disconnecting cleanup ownership, and one recent-expiry wake remain structurally sound. No manager/core lock inversion was found.
- The uplink handoff transfers at most one Event to a globally bounded worker pool, clears not-yet-started payload ownership on terminal cancellation, and does not run the sink on the protocol executor.
- Core/SDK/Viewer boundaries remain compliant: Core changes are platform-neutral SPI, Viewer policy and UI stay under `Viewer`, and there is no third-party Core/SDK dependency, nested manifest, wire-schema change, or supported SDK API expansion.
- The implementation evidence is proportionate for this internal Viewer change: focused behavior, full Swift package regression, bootstrap/TLS/distribution gates, format/diff/OpenSpec validation, and built privacy inspection all have saved successful results. The explicitly deferred signed-release checks are outside this change's behavior and remain assigned to release hardening.

## Focused Validation

Command:

```text
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-round3-architecture CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests
```

Result: passed, exit 0. This independently confirms the current 20-test focused suite, including both mailbox retry paths, partial approval input, exact receiver TTL, typed drop summaries, bounded consumer isolation, recent-row expiry, policy behavior, diagnostics, and bidirectional Event exchange. The linker emitted only the existing macOS 13 test-target/newer-XCTest warnings.

Saved evidence additionally records:

- 74 selected Viewer regression tests passed with zero failures;
- 530 Swift package tests passed with zero failures;
- the repository bootstrap gate passed all 29 items and its iOS, TLS, SwiftPM, CocoaPods, and module-boundary checks;
- strict format, diff, OpenSpec, privacy-manifest, and requirement-to-evidence checks passed.

## Verdict

**Approval withheld.** All four Round 2 architecture findings are resolved, and the validation scope is proportionate. One new receipt-time/service-ordering defect can still close valid retained Event input, and the new oldest-wait telemetry introduces an avoidable bounded hot-path scan.

**Exact unresolved actionable finding count: 2 — 0 High, 1 Medium, 1 Low.**
