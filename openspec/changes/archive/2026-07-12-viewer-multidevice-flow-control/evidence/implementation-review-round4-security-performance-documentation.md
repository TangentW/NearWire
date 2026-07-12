# Implementation Review Round 4: Security, Performance, and Documentation

## Scope and Verdict

This independent review re-read the current uncommitted diff, active proposal/design/spec/tasks, the Round 3 architecture/API and security/performance/documentation reports, the retained-receipt service remediation, the heap-indexed oldest-wait implementation and tests, the operator documentation, and the updated implementation/privacy/requirement evidence. No production, test, specification, task, or existing evidence source was modified; this report is the only file added by this review.

The review assessed the three current-tree bootstrap reruns proportionately under the product owner's explicit no-overengineering direction. The gate was not weakened: each run failed in a different pre-existing asynchronous test, each failure passed immediately in isolation, and the directly affected current-tree suites pass independently and repeatedly.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**

**Approved for the security, performance, and documentation dimension.**

## Round 3 Architecture Finding Disposition

| Round 3 finding | Round 4 disposition |
| --- | --- |
| Later service time can overtake an older retained receipt | Resolved. Nonterminal queue/token/batch/throughput service is deferred while a complete suffix is owned. Policy timeout arbitration remains active, the existing finite same-core continuation remains the sole suffix progress owner, and service is recomputed when the suffix drains. |
| Oldest-wait telemetry performs a full queue scan per Viewer snapshot | Resolved. Viewer now queries a heap-indexed oldest enqueue value. Live-node validation removes stale minima lazily, mutation-time compaction bounds hidden stale nodes, and clear resets the index. |

## Retained-Suffix Service Deferral

### Ordering and timeout semantics

- `pausedOnCompleteFrame` records the preserved receipt sample. Only `needsMoreBytes` or `drained` releases that ownership, and release recomputes the next service wake (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:317-333`).
- A fired one-shot task removes its own task/deadline ownership before calling the session service turn (`ViewerMultiDeviceSession.swift:639-657`). If a complete suffix is still owned, the service turn returns without touching queue, token, batch, expiry, or throughput clocks (`ViewerMultiDeviceSession.swift:667-686`). It does not schedule itself again and therefore creates no idle or immediate polling loop.
- Policy timeout is intentionally evaluated before the deferral guard. A suffix sampled before the deadline records `deadlineElapsed` and continues the already-owned finite bytes; a suffix sampled at or after the deadline closes. When a deferred suffix drains without a matching acceptance, the synchronous terminal-without-resume disposition closes without rearming receive (`ViewerMultiDeviceSession.swift:317-333,536-545,667-675`). Deferral therefore cannot extend or bypass the policy deadline.
- The connection core still owns at most one generation-bound receive-pause token and one same-queue continuation. Each continuation processes a finite frame/record quantum, preserves the original callback receipt, and either schedules its one successor, resumes one receive on partial/drained ordinary input, or terminates. Terminal cleanup invalidates the continuation, decoder residue, and token.

### Progress, starvation, and resource ownership

The deferral path has no independent retained work item: the fired service task is cleared, while the pre-existing decoder continuation remains scheduled on the sole core executor. Mailbox or other real progress may submit another one-shot service turn, but each such turn returns once while the suffix is owned and cannot create a successor. When decoder progress releases the suffix, `scheduleServiceWake` recalculates the earliest policy, token, batch, or TTL boundary from current monotonic time.

The retained bytes remain inside the already-bounded decoder/input budget, the channel cannot arm another receive, and a malicious peer cannot append new bytes during the pause. The suffix is therefore finite and cannot create an idle leak or unbounded starvation state. Physical terminal, explicit disconnect, and shutdown continue to cancel it immediately.

The focused regression constructs both submission orders—continuation first and later service first—and asserts identical active state, Event counts, queue state, drops, throughput, receive-pause ownership, and zero cancellation (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:376-476`). Saved evidence additionally records 20/20 repeated executions of this exact test.

## Heap-Indexed Oldest-Wait Verification

- Each admitted Event inserts one `EnqueueHeapNode` ordered by enqueue time, ordinal, and Event ID (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:164-175,834-860`). Viewer oldest-wait lookup reads the valid minimum in logarithmic/lazy-cleanup form rather than materializing and scanning all queue Events (`BoundedEventQueue.swift:241-247`).
- A heap node is live only when its ordinal still resolves to the same Event ID and enqueue timestamp. Keep-latest replacement, priority removal, expiry, dequeue, and clear therefore cannot make a stale node authoritative; stale minima are popped until a live node or an empty heap is reached (`BoundedEventQueue.swift:907-917`).
- Hidden stale nodes remain bounded. After queue mutations, any deadline heap, enqueue heap, or aggregate priority-heap count above `max(64, liveCount * 2 + 16)` rebuilds all indexes from the live event dictionary (`BoundedEventQueue.swift:997-1034`). At the Viewer 5,000-Event bound and Core 10,000-Event hard bound, retained index storage therefore remains linearly bounded.
- `clear` resets every heap and map, while the queue's monotonic observation validation prevents an underflowing wait calculation (`BoundedEventQueue.swift:777-797,820-832`).
- The old allocating full scan has been removed from the Viewer's frequent oldest-wait publication path. The richer Core `snapshot` operation still performs its intentional bounded scan to derive all four priority counts; Viewer does not call that operation merely to obtain oldest wait.

Queue tests cover live oldest selection after keep-latest replacement, priority removal, clear, 256 repeated replacements that create stale heap nodes, and a 10,000-entry hard-bound fill/drain (`Core/Tests/NearWireFlowControlTests/BoundedEventQueueTests.swift:958-1039`). This reviewer independently reran all 39 `BoundedEventQueueTests`; they passed with zero failures.

## Documentation, Privacy, and Signing Boundary

- The operator guide accurately documents session/recent-row ownership, queue and input limits, service slices and aggregate work, system rate/burst, retained receive ownership, typed drops, oldest wait, closed terminal categories, content-free diagnostics, memory-only exclusions, and the globally capped one-Event consumer boundary (`Documentation/Viewer-MultiDevice-Flow-Control.md:9-63`).
- Persistence remains limited to the bounded requested-policy and nickname record. Event content, metadata, queue values/keys, encoded frames, session epochs, effective policy, endpoints, TLS material, and recent session state remain absent from persistence and unintended output surfaces.
- The independently inspected built manifest contains UserDefaults reason `CA92.1`, linked Device ID for App functionality, tracking false, and no tracking domains. This matches `privacy-manifest-inspection.md` and the operator rationale.
- The two signed-package checks require configured, unrelated signing identities and were not made optional by this change. Their deferral is explicit in the operator guide, implementation evidence, requirement audit, Viewer foundation guide, and roadmap. `release-hardening` is a terminal gate that cannot complete without the A/unrelated/B cross-update Keychain proof (`Documentation/Implementation-Roadmap.md:103-107`). This is an accurate scope deferral, not a weakened security claim.

## Validation Evidence and Bootstrap Assessment

Saved current-tree evidence records:

- 22 focused Viewer flow-control tests passed, including retained-receipt ordering and heap-backed oldest-wait presentation.
- The retained service-order test passed 20/20 repeated runs; the formerly intermittent bidirectional test passed 50/50 repeated runs.
- 76 selected Viewer regressions passed with zero failures.
- `swift test` passed 531 tests with zero failures, and the focused Core queue suite passed all 39 tests.
- The complete pre-remediation bootstrap passed all 29 gates, including 531 iOS and 206 Core tests, real TLS integrations, SwiftPM, CocoaPods, and repository validation.
- Strict formatting, `git diff --check`, strict OpenSpec validation, built privacy inspection, and the requirement-to-evidence audit passed.

After the two narrow Round 3 fixes, three exact unweakened bootstrap reruns failed in three different asynchronous tests:

1. an SDK transport-capacity wake test;
2. an existing secure-channel test that observed the fake driver before its asynchronous send arrived;
3. a discovery snapshot-coalescing timing test.

Each passed immediately when rerun alone. The first and third are outside the changed service-order and queue-index paths. The second is in an affected Core suite, but the test itself was not changed by this remediation and passed in the full 531-test Swift run and its isolated rerun. There is no repeated failure signature, common affected invariant, or evidence that a timeout/gate was weakened. Given the successful broad current-tree suites, repeated focused affected-path tests, prior complete gate, and transparent recording of every failure, these runs are proportionate evidence of environment/load-sensitive test timing rather than an unresolved product defect.

This reviewer independently reran the current 22-test Viewer flow-control suite and all 39 Core queue tests; both passed. Strict OpenSpec validation and `git diff --check` also passed.

## Approval

No unresolved security, privacy, performance-isolation, idle-polling, starvation, timeout-arbitration, resource-retention, stale-index, documentation, signing-scope, or validation-evidence finding remains in this review dimension. The change may proceed to the remaining independent review, audit, archive, and commit gates.
