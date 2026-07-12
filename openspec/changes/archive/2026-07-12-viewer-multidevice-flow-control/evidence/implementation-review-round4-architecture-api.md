# Implementation Review Round 4 — Architecture and API

Date: 2026-07-13

## Scope

Independently reviewed the current uncommitted `viewer-multidevice-flow-control` implementation after Round 3 architecture remediation. The review re-read `AGENTS.md`, the active proposal/design/spec/tasks, the Round 3 architecture report, current Core queue and Viewer session changes, new focused tests, and updated implementation/bootstrap evidence. No production, test, specification, task, or prior evidence source was modified; this report is the only file added by this review.

Coverage and gate results are evaluated proportionately under the product owner's explicit no-overengineering direction. A deterministic changed-path regression plus broad current-tree package/Viewer coverage is accepted when repeated exact bootstrap attempts fail in distinct unrelated asynchronous tests that immediately pass alone, provided the gate itself was not weakened or skipped.

## Round 3 Finding Disposition

### 1. Resolved — Retained complete suffix defers later nonterminal time-domain mutation

`serviceSession` still performs policy-deadline arbitration first. A due timeout may therefore record `deadlineElapsed` against the preserved suffix receipt, or select terminal state when the suffix is not eligible for deferral (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:667-671`; `ViewerMultiDeviceSession.swift:536-544`). Before queue expiry, token refill/consumption, batch scheduling, throughput publication, or any other ordinary service mutation, it now returns while `ownedSuffixReceipt` exists (`ViewerMultiDeviceSession.swift:672-686`).

This ordering preserves the intentionally special policy-timeout winner without advancing the queue/token time domain from `t0` to a later wake time `t1`. When decoder progress reaches `needsMoreBytes` or `drained`, the session clears suffix ownership and recomputes its one service wake from the current scheduler time (`ViewerMultiDeviceSession.swift:317-333`). The admission core then applies ordinary decoder progress and atomically detaches/resumes the receive-pause token (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:613-681`). If a matching acceptance inside the suffix already cleared ownership, `acceptPolicy` has independently committed the pre-deadline receipt and scheduled current policy/service state, so no wake is lost (`ViewerMultiDeviceSession.swift:502-533`).

No queue/token/throughput clock can now overtake a retained complete frame. Terminal, shutdown, decoder failure, and recorded-timeout partial/drained paths continue to cancel rather than rearm.

### 2. Resolved — Both submission orders have equivalent observable state

`testRetainedEventContinuationDefersALaterBatchServiceTurn` constructs the required conflict rather than merely advancing time after the fact (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:376-476`):

- both runs queue one downlink Event with a due 500 ms batch wake;
- both supply 64 complete pings followed by one Event in the same receipt sample, forcing the Event into a retained continuation;
- the service-first run advances the deadline inside the receive-pause claim hook and deliberately gives the wake executor time to submit before the callback returns;
- the continuation-first run drains the retained Event before advancing the same deadline.

The resulting value compares terminal state, receive/deliver/send counts, both queue counts, drop/TTL outcome, ingress/egress throughput, cancellation count, and pause claim/resume counts. Both runs remain active with one contiguous inbound Event accepted and one downlink Event admitted; no queue residue, drop, terminal, or extra pause result differs. Static inspection completes the sequence/token proof: the deferred service branch mutates none of the tentative queue, batch, output sequence, ingress/delivery/send token buckets, or throughput state before continuation, so both orders enter those operations from identical values.

The saved evidence records 20/20 repetitions passing. This review independently ran the same test for five iterations; all five passed with exit 0.

### 3. Resolved — Oldest-wait uses a bounded stale-node-safe enqueue heap

`BoundedEventQueue` now maintains a dedicated min-heap keyed by enqueue time, ordinal, and Event ID (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:164-176,220-228`). Insertion adds one node, and `oldestWaitNanoseconds` validates/pops stale minimum nodes until it finds the exact live ordinal/ID/enqueue-time tuple (`BoundedEventQueue.swift:241-247,834-860,907-918`). It no longer maps or scans all live Events and allocates no full-queue array in Viewer snapshot publication.

The ownership cases are coherent:

- keep-latest replacement may reuse an ordinal, but its new Event ID/time makes the old enqueue node stale;
- arbitrary dequeue, overflow, expiry, and route removal delete the authoritative dictionary entry, so a later heap lookup discards their stale nodes;
- `clear` resets the enqueue heap together with all other indices (`BoundedEventQueue.swift:780-797`);
- heap compaction includes `enqueueHeap.count` in its threshold and rebuilds exactly one enqueue node for every live stored Event (`BoundedEventQueue.swift:997-1033`).

The focused Core test exercises keep-latest replacement with ordinal reuse, priority-based arbitrary removal, the next-oldest live value, and clear-to-empty (`Core/Tests/NearWireFlowControlTests/BoundedEventQueueTests.swift:958-990`). The existing repeated keep-latest test drives stale-node compaction, while the current implementation inspection confirms the enqueue heap participates in the same rebuild. Saved current-tree evidence reports all 39 queue tests and all 531 package tests passing.

## Bootstrap Evidence Assessment

The exact unmodified `./Scripts/verify-bootstrap.sh` gate passed completely before the two narrow Round 3 remediations. After those changes it was rerun three times without weakening commands, timeouts, or selected tests. The failures were:

1. an SDK transport-capacity no-poll timing assertion;
2. a secure-channel FIFO test observing its fake driver before the asynchronous send arrived;
3. a Viewer discovery snapshot-coalescing/terminal-priority timing assertion.

Each failure occurred in a different pre-existing asynchronous test, none touches the retained-suffix service deferral or enqueue-time heap, and each test passed immediately when rerun alone. One attempt advanced through the complete iOS stage and passed all 39 `BoundedEventQueueTests` before the unrelated secure-channel timing failure. In the same current tree:

- the changed Viewer ordering regression passed 20 recorded repetitions plus five independent repetitions in this review;
- all 22 focused Viewer flow-control tests passed;
- 76 selected Viewer regression tests passed;
- all 39 Core queue tests passed;
- all 531 Swift package tests passed;
- format, diff, strict OpenSpec, packaging/privacy inspection, and the prior complete bootstrap gate passed.

Requiring repeated whole-repository reruns until one random combination is green would not add evidence about these two changes and would encourage timeout/gate manipulation. The three distinct, non-reproducing failures are therefore recorded as unrelated suite flakiness, not an unresolved finding in this change. The bootstrap gate itself remains intact for future repository work.

## Additional Architecture Checks

- Same-core decoder, callback, receipt-sample, pause-token, and terminal ownership remain singular across automatic and approval handoff.
- The service deferral owns no new timer or continuation. A wake that observes a suffix clears its current task; suffix release recomputes at most one replacement wake.
- Policy timeout, physical terminal, cancellation, and shutdown retain priority over ordinary deferred work and cannot revive receive ownership.
- The enqueue heap is Core platform-neutral SPI state, adds no supported SDK API, and preserves the queue's count/byte/priority/deadline indices and deterministic semantics.
- Session/manager lock ordering, 16-owner lifecycle, 64 recent rows, mailbox atomicity, aggregate service quantum, 2 MiB/19 MiB input bounds, snapshot-handler synchronization, and Core/SDK/Viewer repository boundaries remain sound.
- No new dependency, manifest, wire field, entitlement, persistence surface, or scope expansion was introduced by the remediation.

## Validation Performed in This Review

Command:

```text
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-round4-architecture CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests/testRetainedEventContinuationDefersALaterBatchServiceTurn -test-iterations 5
```

Result: passed, exit 0. Five of five iterations passed. The build emitted only the existing macOS 13 test-target/newer-XCTest linker warnings.

A direct `swift test --filter BoundedEventQueueTests` attempt could not compile the package manifest because this review sandbox denies writes to `/Users/tangent/.cache/clang/ModuleCache`. This is an environment limitation, not a contradictory test result. The current-tree 39/0 focused queue and 531/0 full package results are already saved in `implementation-validation.md`.

`git diff --check` passes for this report.

## Verdict

**Approved.** Both Round 3 architecture findings are resolved, their ownership and edge cases are covered proportionately, and no new actionable architecture/API defect was found. The three exact bootstrap reruns provide transparent evidence of unrelated non-reproducing asynchronous flakes rather than a changed-path regression or weakened gate.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**
