## Context

The event-model change provides immutable events, priorities, TTL values, IDs, and bounded content, but it deliberately implements no waiting, scheduling, or rate policy. NearWire must buffer while disconnected and while a negotiated rate is lower than production, yet every finite queue eventually fills under sustained overload. The Core contract therefore needs exact admission, replacement, expiration, eviction, fairness, rate, and batching semantics before transport and SDK session code depend on it.

Important constraints are:

- Core remains platform-neutral, dependency-free, Sendable, Swift 5 language-mode code for iOS 16 and macOS 13.
- The iPhone default per-direction business queue is 1,000 events and 4 MiB; Viewer queues later choose larger configurations with the same primitives.
- Event content is already limited to 256 KiB by default. Flow control receives an accounted byte cost rather than guessing the future wire-frame size.
- `.normal` and `.keepLatest(key:)` are queue policies, not delivery guarantees.
- Session sequence must describe actual transmission order. Priority scheduling can reorder pending work, so sequence cannot be allocated before this queue drains.
- iPhone and Mac monotonic clocks are unrelated. Every queue operates only on timestamps captured from its own injected clock domain.
- Control messages use a separate future lane and never enter the business-event queue or token bucket.

## Goals / Non-Goals

**Goals:**

- Bound pending business work by both event count and accounted bytes.
- Make normal queueing, keep-latest replacement, TTL, overflow, clearing, and telemetry deterministic.
- Give critical and high priorities more service without starving normal or low work.
- Express Viewer/App rate negotiation and zero-rate pause safely.
- Provide a deterministic token bucket and batch planner using explicit monotonic time.
- Avoid sleeps, timers, global clocks, actors, network calls, and disk I/O in Core tests.
- Preserve enough result detail for later SDK results and Viewer queue diagnostics without implying remote delivery.

**Non-Goals:**

- Public `NearWire` SDK policy, result, configuration, or telemetry types.
- Connection state, offline-retention ownership, active-disconnect clearing policy, or Viewer switching.
- Session epoch or sequence allocation, wire encoding, framing, compression, TLS, or network sending.
- Control-lane limiting, event ACK, retry, deduplication, exactly-once, or disk persistence.
- Timer ownership or background execution.
- Queue rates measured from wall-clock time.

## Decisions

### 1. Queue generic pending values, not complete envelopes

`PendingEvent<Value>` is a Sendable value containing an event ID, generic value, priority, `EventTTL`, queue policy, accounted byte count, and origin-local enqueue monotonic nanoseconds. It deliberately has no direction, endpoint, session epoch, or sequence.

The SDK can later queue a pre-session event record and allocate session-owned metadata only when an item is selected for transmission. This keeps priority reordering compatible with monotonically increasing wire sequence and lets App uplink work survive a reconnect into a new session epoch.

Alternatives considered:

- Queueing `EventEnvelope` was rejected because its preassigned sequence can conflict with priority scheduling and because offline work may cross session epochs.
- Queueing only `EventDraft` was rejected because SDK enqueue results need a stable event ID and local creation metadata before transmission.

### 2. Treat byte accounting as explicit trusted metadata

Each entry supplies `accountedByteCount`. The queue validates it as positive, below the configured single-event maximum, and within total queue capacity. Later SDK and wire layers own the exact encoding used to calculate the cost; Core never repeatedly serializes generic values on a caller's actor.

Tests use explicit costs, making count and byte boundaries independent. The queue exposes no bypass that mutates stored costs.

### 3. Validate queue configuration as a coherent invariant

`EventQueueLimits` defaults to 1,000 events, 4 MiB total, and 256 KiB per event. Count, byte, and single-event limits are positive and hard-bounded; single-event bytes cannot exceed total queue bytes. The hard count bound is 10,000, which covers the planned 5,000-event Viewer queue while bounding every internal index.

Viewer code may construct 5,000-event and 16 MiB limits later. Invalid or arithmetically unsafe configurations fail before a queue exists.

### 4. Coalesce before applying overflow

`EventQueuePolicy.normal` always creates a distinct pending item. `keepLatest` contains a validated 1–128 UTF-8 byte key without control characters. A queue has at most one pending entry per keep-latest key.

Pending event IDs are unique within a queue. Enqueue rejects a duplicate before coalescing or overflow so ID-based expiration, eviction, and delivery telemetry stays unambiguous.

When a matching key exists, the old entry is removed and the new entry takes its logical insertion ordinal. The new ID, value, priority, byte cost, enqueue time, and TTL replace all old payload metadata. Coalescing is recorded even if later overflow evicts the replacement. Keys are queue-local and are not forced to equal event type.

Coalescing first prevents avoidable eviction and makes a larger replacement participate honestly in byte-limit enforcement.

### 5. Expire before admission, selection, and observation

Every mutating queue operation accepts explicit `nowNanoseconds` from the queue's clock. It removes expired entries before admission or dequeue. A telemetry snapshot also requires a mutable expiration pass so reported depth never includes stale work.

Expiration uses the entry enqueue timestamp and TTL with overflow-safe arithmetic. A clock value earlier than an entry timestamp or an overflowing deadline is a typed error and leaves the operation atomic. The API labels values as same-clock inputs; it never compares sender and receiver uptimes.

### 6. Evict the oldest entry in the lowest present priority

After expiration and optional coalescing, enqueue inserts the new entry, then repeatedly restores both count and byte limits. Each eviction selects the lowest priority currently present and the oldest insertion ordinal within that priority. The incoming entry can therefore be evicted when it is the only lowest-priority candidate; this protects existing urgent work rather than silently letting a low-priority producer evict critical events.

The enqueue result reports the coalesced ID, all overflow-evicted IDs, and whether the incoming event remains buffered. Passive eviction increments counters and does not crash or block a producer. A single entry above the configured per-event or queue-byte limit is rejected before mutation.

### 7. Use weighted round-robin with FIFO priority lanes

The internal priority vocabulary is low, normal, high, and critical. Service weights are 1, 2, 4, and 8 respectively. A scheduler cycle gives each continuously nonempty lane at most its weight, always choosing higher priority first among lanes with remaining credit. When no nonempty lane has credit, credits reset.

FIFO is preserved by insertion ordinal within each priority. A continuously nonempty low lane receives service at least once per complete 15-event cycle, so urgent work gets preference without starvation. Empty lanes do not waste capacity. Global enqueue FIFO is intentionally not promised across priorities; future sequence is assigned in selected order.

Queue storage uses ordinal-keyed values, constant-time ID and keep-latest indexes, per-priority minimum heaps, and a deadline minimum heap. Stale heap nodes are generation-checked through event IDs and periodically compacted. Enqueue, expiration, overflow, and one-at-a-time dequeue therefore avoid whole-queue rebuilding on every event while preserving deterministic ordinal order.

Weighted round-robin was chosen over strict priority, which can starve, and byte-deficit scheduling, because product policy limits events per second and each event consumes one token regardless of size.

### 8. Keep queue telemetry cumulative and explicit

`EventQueueStatistics` tracks non-expired enqueue admissions, dequeued, overflow-dropped, expired, coalesced, and explicitly cleared totals using overflow-reporting arithmetic. An admitted incoming event increments `enqueued` even if overflow immediately drops it; `isBuffered` and affected IDs describe the final state. A mutable snapshot expires due work, then contains current count, accounted bytes, counts by priority, and oldest same-clock wait nanoseconds.

Enqueue and dequeue results carry exact affected IDs for later diagnostics. Clearing accepts a Core reason enum, returns removed IDs, updates the matching counter, and does not decide when a session should clear.

### 9. Represent rates as finite validated events per second

`EventRateLimit` accepts zero or a finite `Double` from 0.000000001 through 100,000. Zero means the business-event direction is paused. The positive minimum keeps the next-token delay representable in `UInt64` nanoseconds. `DirectionalEventRates.effective` computes uplink and downlink independently as the minimum of Viewer-requested and App-local maximum values.

The model does not attach direction semantics to one ambiguous number, and it does not let either endpoint raise the other's cap.

### 10. Use a monotonic token bucket with explicit reconfiguration

`EventTokenBucket` stores rate, burst duration, capacity, available fractional tokens, and last-update nanoseconds. Burst duration defaults to two seconds and is finite, positive, and bounded. Zero rate has zero capacity; positive capacity is `max(1, rate × burstDuration)` so sub-one rates can accumulate a whole token. A new bucket starts full, permitting the documented bounded burst. One event costs one whole token.

Before inspection or consumption, the bucket refills by elapsed monotonic nanoseconds and caps tokens at capacity. Backward clock movement is a typed error with no mutation. Reconfiguration first refills under the old rate at the supplied time, then replaces rate/capacity and clamps existing tokens. Changing from zero to a positive rate does not manufacture a burst; tokens accrue from that point. Changing to zero sets capacity and tokens to zero.

The batch planner asks how many whole tokens are available, drains the queue, and then consumes exactly the number actually selected. Byte-limited short batches therefore do not lose unused tokens.

### 11. Make batching a caller-driven planner, not a timer

`EventBatchLimits` defaults to 256 events, 512 KiB, and a 500 ms flush interval. Its single-batch byte limit must be at least the queue's single-event limit when the two are composed.

`EventBatchScheduler` stores the exact queue limits supplied at construction and rejects a batch limit that cannot fit that queue's largest valid event. `drainIfDue` takes an explicit time, the matching queue, and a token bucket. Before the deadline it returns no batch. At or after the deadline it expires stale entries, determines whole-token allowance, selects fairly until count, bytes, tokens, or the next selected entry would exceed remaining batch bytes, consumes exactly selected tokens, and advances the next deadline to `now + interval`. It does not replay missed intervals or create catch-up flush storms.

An empty or paused due flush returns no batch but still advances the deadline. When no token is available, the scheduler runs an expiration-only path against the deadline heap instead of constructing a full queue snapshot. Returned batches are nonempty and contain their total accounted bytes. The planner exposes the next deadline and token wait estimate so later actors can schedule efficiently.

### 12. Preserve atomic mutation and deterministic tests

Queue and bucket operations validate time and arithmetic before committing visible changes. The batch scheduler validates its small bucket copy before mutating the indexed queue, then performs only invariant-preserving token deduction and scheduler assignment after a successful drain; it does not copy the full queue for transactional control. Core types are mutable structs intended to be owned by a later actor; they do not introduce internal locks or claim thread safety for simultaneous mutation.

Tests use explicit nanosecond values and fixed IDs. No test sleeps, reads global uptime, starts a timer, or depends on scheduler timing.

## Risks / Trade-offs

- **[Risk] Generic byte cost may differ from final wire bytes** → Require the owning layer to use one documented accounting codec and let the future wire layer reject a frame that independently exceeds protocol limits.
- **[Risk] Priority reordering surprises callers expecting global FIFO** → Document FIFO only within priority and allocate sequence after dequeue.
- **[Risk] A low-priority incoming event can be immediately evicted** → Return `isBuffered` and exact evicted IDs; do not mislabel local acceptance as delivery.
- **[Risk] Keep-latest replacement changes priority while retaining ordinal** → Preserve logical state position but move it into the new priority lane; test both promotion and demotion.
- **[Risk] Large elapsed time loses floating-point refill precision** → Bound rates and burst capacity, calculate elapsed seconds carefully, cap before consumption, and test `UInt64` time boundaries.
- **[Risk] Batch head does not fit remaining bytes** → End the current batch rather than skipping it and violating fair order; it is eligible at the next flush because each event fits an empty configured batch.
- **[Risk] Cumulative counters can overflow in very long processes** → Use reporting arithmetic and saturate at `UInt64.max`, documenting saturation.
- **[Risk] A caller passes a timestamp from another clock domain** → Label APIs explicitly, document ownership, and keep clock selection in one later session actor.

## Migration Plan

1. Add queue, policy, limits, statistics, rate, bucket, and batch types under the existing NearWireFlowControl target.
2. Add `critical` to the internal Core priority enum and update exhaustive switches.
3. Add deterministic queue, rate, batching, adversarial, and strict-concurrency tests.
4. Add English flow-control documentation and run the locked package, pod, boundary, language, and OpenSpec gates.
5. Complete multi-agent remediation to zero findings, archive the change, and commit before wire-protocol apply begins.

Rollback is a normal commit revert because no SDK facade, persistence format, negotiated protocol, or Viewer database consumes these types yet.

## Open Questions

None. Viewer-specific queue sizes, session disconnect clearing policy, exact wire byte accounting, and actor/timer ownership are intentionally deferred to their named later changes.
