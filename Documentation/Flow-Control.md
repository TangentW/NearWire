# NearWire Core Flow Control

This document describes the internal, platform-neutral queue, rate, and batching primitives shared by later SDK and Viewer layers. They use the `NearWireInternal` Swift SPI only for repository-owned cross-module compilation and are not supported SDK facade API.

## Pending events and session ownership

`PendingEvent<Value>` stores a stable event ID, a Sendable value, priority, event TTL, queue policy, accounted bytes, and a monotonic enqueue timestamp. It intentionally does not contain endpoints, direction, session epoch, or sequence.

Priority scheduling can change transmission order, and buffered App events can survive into a newly connected session. The active session and wire layer must therefore assign session epoch and sequence after dequeue. This ensures sequence reflects actual transmission order instead of pre-queue insertion order.

The queue does not calculate encoded size. Its owner supplies one positive `accountedByteCount` using a consistent encoding policy. A future wire encoder still applies its independent frame-size limit.

## Queue limits and policies

The default queue limits are:

| Limit | Default |
| --- | ---: |
| Pending events | 1,000 |
| Total accounted bytes | 4 MiB |
| One event | 256 KiB |

The count hard bound is 10,000. Viewer queues can use larger configurations, such as 5,000 events and 16 MiB, without changing queue behavior.

Normal events always occupy distinct entries. `keepLatest` uses an explicit queue-local key of 1 through 128 UTF-8 bytes without control characters. A matching pending entry is replaced with the new ID, value, priority, byte count, enqueue time, and TTL while retaining its logical insertion ordinal. Coalescing happens before overflow checks.

Pending IDs are unique within one queue. A duplicate pending ID is rejected atomically so ID-based telemetry remains unambiguous.

Queue policies describe only local memory retention. They do not provide acknowledgement, retry, persistence, at-least-once, exactly-once, or remote processing guarantees.

## Expiration and overflow

Every enqueue, dequeue, and mutable snapshot removes expired work first. TTL uses only the queue's origin-local monotonic clock. A Mac uptime and iPhone uptime are never comparable. Backward time and deadline overflow fail atomically.

After coalescing, the queue restores count and byte bounds by repeatedly selecting the oldest event from the lowest priority present. The priority order is:

1. low
2. normal
3. high
4. critical

An incoming low-priority event can therefore be the item immediately evicted when a full queue contains only critical work. The enqueue result reports whether the incoming event remains buffered, the coalesced event ID, expired IDs, and every overflow-evicted ID.

## Fair priority scheduling

Dequeue uses weighted round-robin credits:

| Priority | Events per full busy cycle |
| --- | ---: |
| low | 1 |
| normal | 2 |
| high | 4 |
| critical | 8 |

FIFO is preserved within each priority. Global FIFO across priorities is not promised. A continuously nonempty low lane still progresses once per 15-event cycle, while empty lanes consume no service opportunity.

Internally, hash indexes provide event-ID and keep-latest lookup, while per-priority and deadline minimum heaps avoid rebuilding or sorting the entire queue for each admission or single-event drain. Stale heap nodes are validated and compacted at a bounded live-entry threshold with a small fixed floor.

If the next fairly selected event cannot fit the remaining batch bytes, selection stops without removing or skipping it. The next flush can send it because a valid batch configuration fits every valid single queue event.

The queue also supports a synchronous offer operation for transport backpressure. It presents the next fair candidate to its owner and removes it only when the owner accepts it. Stopping leaves that candidate's insertion ordinal, indexes, accounted bytes, and weighted scheduler credit unchanged, so a later attempt observes the same ordering without a dequeue-and-reinsert cycle. An owner preflight can remove locally invalid work, such as a stale route-bound reply, before the transport byte budget is evaluated; that work consumes a bounded candidate slot but no transport bytes.

## Telemetry and clearing

Queue snapshots expire stale entries and then report current event count, accounted bytes, counts by priority, oldest same-clock wait, and cumulative totals for enqueue, dequeue, coalescing, expiration, overflow, and explicit clearing. `enqueued` counts each non-expired event admitted to overflow evaluation, including an incoming event that overflow immediately drops; the enqueue result reports final retention. Cumulative counters saturate at `UInt64.max`.

The Core clear operation takes an owner-requested or session-ended reason and returns exact removed IDs. Session code, not Core, decides when App uplink buffers survive or Viewer-specific downlink work must be cleared.

## Directional rate negotiation

Rates are zero or finite values from 0.000000001 through 100,000 events per second. The positive minimum keeps next-token delays representable as monotonic nanoseconds. App uplink and App downlink are always separate. Each effective value is the more conservative endpoint value:

```text
effectiveUplink   = min(viewerRequestedUplink, appMaximumUplink)
effectiveDownlink = min(viewerRequestedDownlink, appMaximumDownlink)
```

Zero pauses that business-event direction. It does not pause the future Control Lane.

## Token bucket

One event consumes one token. Zero rate has zero capacity. Positive capacity is `max(1, rate × burstDuration)`, with a default burst duration of two seconds, so even a sub-one rate can eventually admit an event. A newly created positive-rate bucket starts full, allowing a bounded initial burst.

Refill uses explicit monotonic nanoseconds and keeps fractional tokens. Whole-token inspection does not consume anything. Batch planning consumes exactly the number of events actually removed, so byte-limited batches retain unused token allowance.

Reconfiguration first refills through the change instant at the old rate, then applies the new rate and clamps tokens to the new capacity. Pausing clears tokens. Resuming from zero starts with zero tokens and accrues from that instant, avoiding a synthetic resume burst.

## Caller-driven batching

Default batch limits are:

| Limit | Default |
| --- | ---: |
| Events | 256 |
| Accounted bytes | 512 KiB |
| Flush interval | 500 ms |

`EventBatchScheduler` is not a timer. Construction binds it to one exact queue-limit configuration and rejects a batch byte limit that cannot fit that queue's largest valid event. A later actor calls it with explicit monotonic time and a queue with those limits. Before the deadline it does nothing. At or after the deadline it expires stale work, inspects tokens, drains fairly within count and byte bounds, consumes exact tokens, and sets the next deadline to one interval after the supplied time.

Missed intervals do not create catch-up flushes. An empty or paused due attempt still advances the deadline and uses only the deadline heap to expire due work rather than scanning a full snapshot. The scheduler exposes its next deadline, and the token bucket can report delay until the next whole token; the caller owns all tasks and wakeups.

## Runtime boundary

The flow-control module starts no timer, task, thread, run loop, network operation, disk write, or UI work. Its mutable structs are intended to be isolated by one later actor. They do not add internal locks and do not claim safe concurrent mutation by multiple owners.
