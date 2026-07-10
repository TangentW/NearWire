# Core Flow Control Completion Audit

## Audit basis

- Canonical validation run: `20260710T232302Z-39035`
- Canonical capture status: complete, exit 0
- Automated platform results: iOS 79/79; macOS Core harness 76/76; NearWireFlowControl 43/43
- OpenSpec capabilities: bounded event queue, event rate control, and critical event priority

## Requirement-to-evidence matrix

| Requirement | Implementation and test evidence | Validation evidence | Result |
| --- | --- | --- | --- |
| Session-neutral pending values | Generic `PendingEvent`, stable ID, value, priority, TTL, policy, byte cost, local time; no direction/session/sequence fields | Strict concurrency and boundary gates | Proven |
| Coherent queue limits | Validated defaults and hard bounds; 10,000-entry stress | `raw/08-swift-package.log` | Proven |
| Normal and keep-latest policy | Distinct normal entries, validated Unicode-safe keys, in-place logical ordinal, full metadata replacement | Coalescing, growth, promotion, demotion, and heap-compaction tests | Proven |
| Origin-local TTL | Stored overflow-safe deadlines, monotonic queue clock, expiry before admission/selection/snapshot | Stale admission, TTL reset, exact-ID, paused and token-backed expiration tests | Proven |
| Priority-aware overflow | Lowest priority and oldest ordinal eviction until count and bytes recover | Incoming-drop and multi-eviction tests | Proven |
| Weighted fair dequeue | Persistent 1/2/4/8 credits and ordinal heaps | Full-cycle and cross-call 8/4/2/1 tests | Proven |
| Exact results and telemetry | Exact coalesced, expired, dropped, dequeued, and cleared IDs; saturating counters | Snapshot, duplicate-ID, clear, and saturation tests | Proven |
| Memory-only semantics | Foundation-only values with no timer, task, lock, UI, network, or persistence operation | Boundary, pod, and semantic review | Proven |
| Directional rate negotiation | Independent Viewer/App uplink and downlink minima; zero pause | Negotiation and invalid-rate tests | Proven |
| Monotonic token bucket | Fractional refill, bounded positive capacity, whole-event tokens, safe wait projection | Burst, fractional, minimum-rate, large-time, and clock tests | Proven |
| Pause and reconfiguration | Old-rate refill, capacity clamp, zero clearing, no resume burst, atomic burst changes | Pause/resume, rate decrease, burst decrease/increase, invalid burst tests | Proven |
| Exact token use | Whole allowance inspection and prevalidated deduction of only drained events | Byte-bound and token-bound scheduler tests | Proven |
| Count-byte-interval batches | Validated defaults/hard bounds and exact queue-limit binding at construction | Configuration, count, byte, and queue-mismatch tests | Proven |
| Stable caller-driven scheduling | Explicit deadline, no early work, one late attempt, no catch-up, deadline advance on empty/pause, deadline-heap-only zero-token expiration | Early, exactly due, missed interval, paused, empty, and hard-bound paused tests | Proven |
| Flow observability | Whole tokens, safe next-token delay, next flush deadline, queue snapshots | Rate, snapshot, and schema-only gates | Proven |
| Critical event priority | Codable critical case and exhaustive queue ordering | iOS/macOS package suites and updated event-model documentation | Proven |

## Scenario audit

- Default queue configuration is 1,000 events, 4 MiB total, and 256 KiB per event; the hard event bound is 10,000.
- Every accepted keep-latest key is 1 through 128 UTF-8 bytes and excludes C0, DEL, and C1 controls.
- An incoming event at its exact TTL deadline is reported expired without replacing live state or causing overflow.
- Duplicate live IDs fail before mutation; an expired prior ID can leave through the normal expiration path.
- Overflow can drop the incoming low-priority event and reports final retention independently from admission statistics.
- Priority and deadline heaps validate stale nodes by event ID and compact at a bounded threshold. Full hard-bound fill and one-at-a-time drain complete under the package tests without whole-queue rebuilding per event.
- Queue time is monotonic even when empty, and event deadlines use only the queue clock that supplied enqueue time.
- Positive rates below one event per second have at least one-token capacity and eventually admit work. The minimum supported positive rate returns a duration that is replayed through the refill formula before exposure.
- Pausing clears tokens; resume begins empty. Rate and burst decreases clamp, while increases do not manufacture tokens.
- Scheduler construction binds exact queue limits and rejects an undersized batch before the live loop. Runtime use rejects a different queue atomically.
- The scheduler does not copy the full indexed queue for transactionality. It validates a small bucket copy, drains only after all fallible preconditions, then deducts a proven available token count.
- Empty, paused, and expiration-only due attempts remain distinguishable from early attempts through `EventBatchAttempt` and still advance the deadline.
- Core compiles for iOS 16 and macOS 13 in Swift 5 language mode with complete concurrency checking and warnings as errors.
- SwiftPM products, target paths, dependencies, CocoaPods source mappings, subspec graph, and provenance remain unchanged.

## Review history

- Round 1 found low-rate starvation, stale admission, lost expiration IDs, duplicate-ID ambiguity, Unicode control acceptance, hard-bound drift, quadratic single-call algorithms, and incomplete cross-call fairness coverage. All were corrected with regressions.
- Round 2 found quadratic hard-bound sequences, an early minimum-rate delay, late scheduler composition validation, critical-priority documentation drift, missing burst-change tests, and stale evidence. All were corrected and canonical evidence was recaptured.
- Round 3 found one API-name typo, a full-queue scan on zero-token flushes, and evidence predating the corrections. The name was fixed, the scheduler now uses deadline-heap-only expiration, a hard-bound paused regression was added, and all evidence was recaptured.
- Round 4 reported zero architecture and correctness findings but found one stale sentence naming round 3 as the final zero-finding gate. The audit wording was corrected.
- Round 5 independently reported zero findings in architecture/API, correctness/testing, and security/performance/documentation.

## Expected notes and residual scope

The CocoaPods `example.invalid` warning is the intentional bootstrap placeholder and must be replaced before release. App Intents lines are metadata notes for targets without AppIntents, not compiler diagnostics.

Wire framing, receiver-local TTL establishment, sequence allocation, transport, Bonjour, pairing, control messages, SDK actor/timer ownership, offline retention, persistence, Viewer UI, and metric collection remain assigned to later changes. No flow-control type is part of the supported SDK facade.

## Decision

Every normative requirement and scenario has implementation, automated validation, documentation, and independent review evidence. After the final fresh review round reports zero unresolved findings in all three required dimensions, the change is ready for strict validation, archive into baseline specifications, and commit before `core-wire-protocol` begins.
