# Implementation Review Round 4 — Correctness and Testing

Date: 2026-07-13

## Scope

Independently reviewed the current uncommitted `viewer-multidevice-flow-control` implementation after the Round 3 architecture remediation. The review re-read the active OpenSpec artifacts, current diff, Round 3 architecture and correctness reports, the retained-suffix/service-order changes, throughput-window changes, oldest-wait heap implementation, all 22 focused Viewer tests, all 39 Core queue tests, and the updated implementation-validation and requirement-to-evidence records.

Coverage was judged proportionately. Shared Core, SDK, Viewer-foundation, TLS, package, and bootstrap evidence is accepted where it directly exercises the same primitive or ownership boundary; this review does not require a bespoke Viewer test for every phrase in the task plan. No production, test, specification, or task source was modified; this report is the only added file.

## Round 3 Architecture Finding Disposition

### Finding 1 — Resolved — Retained receipt time now wins over later nonterminal service mutation

The Round 3 defect was a real ordering problem: a later service wake could advance queue/token/batch clocks before an older retained frame continued with its preserved receipt sample. The current implementation closes that ordering gap.

`ownedSuffixReceipt` is installed whenever decoder progress pauses on a complete frame. `serviceSession` may still run policy-deadline arbitration, because that is the specified winner rule, but it returns before queue expiration, token service, batching, throughput publication, or another service wake can advance those time domains (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:317-334,667-686`). The service task clears its old ownership before calling `serviceSession`, so no stale scheduled owner remains.

When the retained suffix finally reaches `needsMoreBytes` or `drained`, `decoderDidProgress` clears `ownedSuffixReceipt` and recomputes the earliest service wake from the current scheduler time. If recorded policy timeout still owns the decision, terminal-without-resume wins instead (`ViewerMultiDeviceSession.swift:325-333`). Thus deferred batch, TTL, and token work is neither lost nor applied retroactively.

The new regression creates an older Event beyond the 64-frame continuation quantum and a later downlink batch deadline. A pause-claim hook advances the injected scheduler and permits the service wake to submit before continuation in one run; the comparison run lets continuation win first. It compares state, received/delivered/sent counts, queue counts, drops, ingress/egress throughput, cancellation count, and pause-token results, then requires the same active outcome in both orders (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:376-476`).

The test passed as part of the focused suite and passed 20 of 20 independent repetitions both in saved evidence and in this review. No queue clock reversal, token rejection, TTL divergence, throughput divergence, sequence loss, or terminal divergence remained.

### Finding 2 — Resolved — Oldest-wait telemetry uses a stale-node-safe live enqueue heap

`BoundedEventQueue` now owns an `EnqueueHeapNode` ordered by enqueue time, ordinal, and Event ID. Insertions add one node; removals remain constant-time in the canonical dictionaries; `validEnqueueNode` lazily removes stale heap roots until it finds the exact current Event identity and enqueue time (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:164-176,220-246,834-918`).

Keep-latest replacement, priority removal, expiry, and ordinary dequeue can leave stale nodes safely. Heap compaction includes the enqueue heap in the same bounded threshold and rebuilds only live Events. Queue clear resets it immediately (`BoundedEventQueue.swift:997-1033`). Viewer snapshot publication therefore no longer allocates and scans a 5,000-element array per queue.

The new queue test covers the important identity transitions: a keep-latest replacement changes priority and enqueue time while retaining its logical ordinal, the replacement is then removed by priority service, the older remaining live Event becomes the heap minimum, and clear produces no oldest wait (`Core/Tests/NearWireFlowControlTests/BoundedEventQueueTests.swift:958-990`). The full 39-test queue suite, including hard-bound fill, repeated replacement/compaction, expiry, priority, fairness, snapshot, and clear behavior, passes.

## Additional Correctness Checks

### Throughput ordering

`rollThroughputWindow` now advances only when the sampled second is strictly newer; an older preserved receipt can never rewind a window that legitimately advanced (`ViewerMultiDeviceSession.swift:926-931`). Downlink egress rolls the window before incrementing its current-second counter (`ViewerMultiDeviceSession.swift:831-839`). Combined with retained-suffix service deferral, later local service cannot reset or mutate throughput before older retained input is classified. The both-order regression includes ingress and egress throughput in its equality oracle.

### Wake and deadline ownership

- A service task that encounters a retained suffix relinquishes its task/deadline fields and performs no nonterminal mutation.
- Suffix release installs a fresh earliest-deadline wake exactly once.
- Policy timeout remains the only permitted arbitration while a pre-deadline suffix is retained.
- Zero-rate or mailbox-blocked business work still does not poll.
- Terminal cleanup cancels the service generation and receive token, clears queues, and prevents a deferred wake from reviving the session.

No lost-wake or immediate-retry loop was found.

### Sequence, queue, and cleanup behavior

The remediation does not move commit points. Inbound sequence, contract tokens, exact receiver deadline, and queue admission remain whole-frame planned values. Downlink queue, fairness, batch, tokens, sequence, and telemetry still commit only after authoritative mailbox ownership. The terminal consumer regression additionally proves that one session can clear its queued uplink while another session continues delivery, without cross-session cancellation or starvation (`ViewerFlowControlTests.swift:648-710`).

## Proportional Validation Assessment

The current evidence contains the following successful current-tree results:

- **22 Viewer flow-control tests:** 22 passed, 0 failed.
- **Retained suffix/service order:** 20 of 20 repeated runs passed.
- **Core queue suite:** 39 passed, 0 failed, including the live-node oldest-wait test.
- **Swift Package suite:** 531 passed, 0 failed. The local command reports 7 platform/environment skips.
- **Selected Viewer regression:** 76 passed, 0 failed after excluding the two explicitly deferred signing-dependent checks.
- **Earlier complete bootstrap:** all 29 gates passed, including iOS compilation/tests, Core/Viewer suites, real TLS integration, SwiftPM, CocoaPods, module boundaries, and repository validation.
- Strict Swift formatting, `git diff --check`, strict OpenSpec validation, built privacy inspection, and requirement-to-evidence audit pass.

After the two Round 3 architecture fixes, the exact unweakened bootstrap script was rerun three times. The attempts failed in three different existing asynchronous timing tests:

1. `SDKSessionAdmissionTests.testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress`;
2. `SecureByteChannelTests.testSendsAreFIFOAndBackpressureIsAtomic` after all 39 queue tests had passed;
3. `ViewerDiscoveryTests.testIngressCoalescesSnapshotsAndGivesTerminalPriority`.

Each test passed immediately when rerun alone. None exercises the changed Viewer retained-suffix service-order path or the new enqueue-heap telemetry index. The failures rotate across SDK admission, Core driver observation, and discovery-ingress scheduling, while the complete current-tree 531-test package run, 39-test queue run, 22-test focused Viewer run, and 76-test selected Viewer run all pass.

The repository correctly preserved these failures instead of increasing timeouts, disabling tests, or weakening `verify-bootstrap.sh`. On this evidence, the three bootstrap outcomes are an explicit environment/timing limitation rather than a reproducible product regression or a correctness action attributable to this change. Requiring another bespoke test for every task phrase would not add material confidence to the remediated seams.

## Validation Performed in This Review

### Focused Viewer suite

```text
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-r4-correctness-review CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests
```

Result: **passed, exit 0.** The source contains 22 selected test methods.

### Retained-suffix ordering stability

```text
xcodebuild test-without-building -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-r4-correctness-review CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests/testRetainedEventContinuationDefersALaterBatchServiceTurn -test-iterations 20
```

Result: **passed, exit 0; 20 of 20 iterations passed.**

### Core queue suite

```text
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-r4-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-r4-swiftpm-cache swift test --disable-sandbox --filter BoundedEventQueueTests
```

Result: **passed, exit 0; 39 tests, 0 failures.**

### Complete Swift Package suite

```text
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-r4-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-r4-swiftpm-cache swift test --disable-sandbox
```

Result: **passed, exit 0; 531 tests, 7 skipped, 0 failures.** The cache warnings reflect read-only user-level SwiftPM cache directories; build/test output used the explicit writable `/tmp` module caches.

### Selected Viewer regression

```text
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-r4-selected-review CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result: **passed, exit 0.** The selected source set contains 78 test methods and excludes exactly the two named signing tests, matching the saved 76-test xcresult count.

Additional checks:

- `git diff --check`: passed with no output.
- `env DO_NOT_TRACK=1 openspec validate viewer-multidevice-flow-control --strict --no-interactive`: passed; the change is valid.

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

Both Round 3 architecture findings are resolved. Retained receipt time is protected from later service mutation in both submission orders, throughput cannot rewind, oldest-wait telemetry is heap-indexed and live-node safe, and the focused plus shared validation evidence is proportionate. The recorded bootstrap instability is not reproducible in isolation and does not identify an actionable defect in the changed paths.
