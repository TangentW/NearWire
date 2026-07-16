## MODIFIED Requirements

### Requirement: Multi-device owner exposes bounded live presentation and typed control admission without transferring protocol ownership

One runtime-components factory SHALL create the exact session manager, typed control facade, manager generation, memory projection, and bounded journal for one explicit runtime logical ID. The manager SHALL NOT generate a different hidden runtime ID and application code SHALL NOT recover control by downcasting the handoff owner.

At each committed uplink or secure-mailbox-admitted downlink boundary, the manager SHALL create one immutable normalized observation shared by protocol diagnostics and the memory projection. It SHALL contain one Viewer wall/monotonic receive time, runtime/connection identity, bounded frozen App/Bundle/display aliases, Event value, deterministic byte count, direction/sequence, and initial disposition. Every current-Session consumer SHALL use those exact receive times rather than resampling later.

The protocol callback SHALL offer observations to a 64-record/20-MiB fixed ingress using precomputed deterministic Event bytes plus fixed maximum metadata/entry overhead and a constant number of lock/index/ring operations. The ingress byte bound SHALL admit one maximum legal encoded journal Event plus that fixed maximum overhead. It SHALL perform no eviction, large-value release, JSON encoding, content traversal, MainActor wait, task per Event, or network mutation. At most one serial projection drain plus one dirty successor SHALL maintain an O(1) deque/exact-key index retaining at most 32 MiB of accounted Event data. It SHALL NOT evict because of an independent fixed Event count. Finite deque and marker storage SHALL be derived from the byte budget divided by minimum fixed per-Event accounting overhead and SHALL represent every byte-valid snapshot. Displaced values SHALL release outside the state lock. Deterministic bytes SHALL be documented as accounting, not actual Swift heap; callback latency and heap high-water SHALL be measured.

The projection SHALL also retain at most 16 frozen Session metadata rows, exact later terminal disposition per retained Event, one positive-drop/cumulative sample per Device, Session end, and bounded overflow/conflict gap state. Lock-side authority and pending per-key disposition/conflict state SHALL cover the byte-derived retained-slot capacity plus the 64 fixed ingress slots so every accepted pending Event can preserve its metadata while the projection executor is blocked. Normal accepted disposition SHALL update the exact retained Event without creating a separate badge; identical duplicate input SHALL remain idempotent; conflicting content for a retained journal key SHALL preserve the first Event and add one bounded marker. Its latest-only UI wake SHALL run no more than once per main run-loop turn and ten times per second, with at most one evaluation per cadence and none while presentation is paused. Runtime shutdown SHALL join ingress/drain work and clear every Event/Session projection value before the existing cleanup receipt completes.

Its identity SHALL be `(runtime logical ID, connection ID, direction, wire sequence)`. Peer Event UUID SHALL remain content. Duplicate equivalence SHALL compare Event ID/type, canonical content JSON bytes, App-created time normalized once to nearest integer milliseconds since 1970, App monotonic time, priority, TTL, schema version, correlation/reply IDs, and initial disposition. Source, target, and Session epoch SHALL be validated against the exact Session before commit. Frozen Session metadata, deterministic byte accounting, and newly sampled Viewer receive times SHALL be excluded; the first accounting and receive values remain authoritative, and no hash alone decides equality. While the key remains pending or retained, an identical duplicate SHALL be idempotent and conflicting content SHALL preserve the first observation plus one exact-key `presentationConflict` marker. Ingress rejection SHALL record a saturating gap and return `untracked`. Eviction SHALL end the bounded duplicate horizon and SHALL already produce an overflow marker; no unbounded key tombstone SHALL be retained, and a later candidate MAY become the new first observation. Presentation SHALL NOT infer acknowledgement, alter sequence/queue/token/terminal state, or keep Event content after runtime end.

One immutable projection snapshot SHALL drive filtering and detail without consulting mutable Session state. Runtime gaps apply to every retained Event; Device gaps and positive drops apply to the exact Device; terminal disposition applies to the exact Event; unavailable projection data does not match. Evaluation SHALL scan the complete byte-valid snapshot, bounded by 32 MiB and the derived finite carrier capacity, perform at most 16,384 predicate checks and 1,000,000 JSON-node visits, run at most 100 ms, check cancellation between entries/predicates/path components, and publish no partial result as complete. Literal and typed JSON matching SHALL use the closed current-Session evaluator rather than an external query engine.

The session manager SHALL accept one immutable prepared Event plus 1 through 16 manager-issued opaque target capabilities carrying random token UUID, exact runtime logical ID, manager generation, and connection ID. Capabilities SHALL be memory-only, non-reconstructible by UI, and limited to the exact active/terminal-cache lifetime below. The prepared value SHALL contain the one validated/encoded draft, checked accounted bytes, and normal or event-type-keyed keep-latest policy; no target admission may re-encode, deep-traverse, or deep-copy content. Duplicate token UUID occurrences SHALL all be invalid before admission and unique results SHALL preserve input order.

Classification SHALL be authoritative inside manager/session ownership. At most 16 active capabilities exist. Terminal moves the exact capability into a separate connection-keyed cache capped at 64 entries and retained while elapsed monotonic time is less than 30 seconds; equality expires, and capacity eviction uses oldest terminal time then token UUID lexical order. Same-route reconnect issues a new capability and never removes or satisfies the old entry. Shutdown/full identity reset clears the cache; it is not the route-keyed recent-device presentation. Malformed, duplicate, wrong-runtime, wrong-generation, never-issued, expired, capacity-evicted, or reset-cleared capabilities are `invalidTarget`. On the manager's serial executor, terminal-before-capability-lookup finds the exact terminal entry and is `noLongerConnected`; lookup-before-terminal followed by negotiating/disconnecting state or terminal-before-session-active-check is `notActive`; `queueRejected` requires exact active ownership with negotiated-size or bounded-queue rejection; and `queued` requires that exact session to buffer the prepared draft. Terminal after buffering does not rewrite `queued`. There SHALL be no retry, route retarget, cross-device rollback, secure-mailbox/peer claim, or independent send history.

#### Scenario: Presentation ingress is unavailable while uplink Events commit

- **WHEN** valid contiguous Events commit protocol sequence but bounded presentation ingress cannot accept another observation
- **THEN** one saturating memory-window gap records the unavailable presentation horizon
- **AND** presentation loss changes no connection, sequence, queue, token, timeout, or terminal decision

#### Scenario: More than 512 small Events remain within the byte budget

- **WHEN** projection contains more than 512 Events but remains within 32 MiB of accounted data
- **THEN** it retains those Events without count-triggered displacement
- **AND** exact-key authority, diagnostics, evaluation, and Timeline publication remain bounded by the same byte-derived carrier capacity

#### Scenario: Live callback ingress or window reaches a bound

- **WHEN** callback ingress would exceed 64 entries/20 MiB or projection would exceed 32 MiB of accounted Event data
- **THEN** callback admission remains constant-work, one saturating gap records rejected/displaced presentation values, and projection eviction occurs only on its executor
- **AND** no producer blocks, no Event is released under the callback lock, and no task/value accumulates per loss

#### Scenario: One selected target is no longer active

- **WHEN** a validated multi-target control draft reaches a target whose exact connection lost active ownership
- **THEN** that target receives `noLongerConnected` or `notActive` while other targets decide independently
- **AND** no new session is selected by route similarity and no delivery claim is made

#### Scenario: Same live key arrives with conflicting content

- **WHEN** a second observation reuses runtime/connection/direction/sequence with different Event content while the first key remains retained
- **THEN** the retained first Event remains, one bounded presentation-conflict marker is coalesced, and the duplicate does not replace it
- **AND** no protocol outcome is changed

#### Scenario: Conflicting key returns after memory eviction

- **WHEN** the first key was evicted and a later candidate reuses that key
- **THEN** the existing overflow diagnostic discloses the lost horizon and the later candidate may become the new bounded first
- **AND** no unbounded tombstone, global first-wins claim, or protocol mutation is introduced
