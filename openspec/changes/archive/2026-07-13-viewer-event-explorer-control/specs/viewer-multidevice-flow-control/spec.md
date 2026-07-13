## MODIFIED Requirements

### Requirement: Device workspace exposes session control and composes with the Event Explorer

The Viewer sidebar SHALL list negotiating, active, disconnecting, and recently disconnected correlation rows with safe identity hints, nickname, state, and bounded warning indicators. A returning connection SHALL use the ordinary negotiating state; there SHALL be no separate reconnecting state. The workspace SHALL explicitly label App identity, installation alias, Bundle ID, nickname continuity, and recent-row presentation as unauthenticated and SHALL NOT imply that any one proves the returning App. A selected connected device SHALL show editable nickname, requested App uplink/downlink rates, separately labeled effective rates, queue count/bytes/oldest wait, throughput, Event counts, and drop totals. Invalid rate or nickname input SHALL be rejected locally with fixed safe guidance. Disconnected rows SHALL not permit rate mutation.

The workspace SHALL preserve the foundation pairing, approval, pause, and recovery controls and SHALL compose them with the three-column Event Explorer without creating a second session manager or protocol owner. Event content SHALL appear only in the explicit timeline/inspector/composer surfaces; safe device rows, pending/recent rows, queue telemetry, errors, logs, preferences, and generic reflection SHALL remain content-free. Performance projections and charts remain deferred to `viewer-performance-dashboard`.

Controls and state SHALL have accessibility labels and deterministic presentation-model coverage.

#### Scenario: User selects an active device

- **WHEN** an active logical route is selected
- **THEN** its requested and effective rates are clearly distinguished and the same device may scope the Event timeline
- **AND** its current queue and transfer telemetry remain available without exposing Event content in the device row

#### Scenario: Device disconnects while selected

- **WHEN** the selected session terminates
- **THEN** the row enters bounded recent-disconnect presentation or is removed after expiry
- **AND** rate mutation and new control admission are disabled without selecting an unrelated device

## RENAMED Requirements

- FROM: `### Requirement: Device workspace exposes session control without Event history`
- TO: `### Requirement: Device workspace exposes session control and composes with the Event Explorer`

## ADDED Requirements

### Requirement: Multi-device owner exposes bounded live presentation and typed control admission without transferring protocol ownership

One runtime-components factory SHALL create the exact session manager, typed control facade, manager generation, live projection, and composite store/live journal for one explicit runtime logical ID. The manager SHALL NOT generate a different hidden runtime ID and application code SHALL NOT recover control by downcasting the handoff owner.

At each committed uplink or secure-mailbox-admitted downlink boundary, the manager SHALL create one immutable normalized observation shared by store and live paths. It SHALL contain one Viewer wall/monotonic receive time, runtime/connection identity, bounded frozen App/Bundle/display aliases, Event value, deterministic byte count, direction/sequence, and initial disposition. The store SHALL use those exact receive times rather than resampling later.

The protocol callback SHALL offer observations to a 64-record/20-MiB fixed ingress using precomputed deterministic Event bytes plus fixed maximum metadata/entry overhead and a constant number of lock/index/ring operations. The ingress byte bound SHALL admit one maximum legal encoded journal Event plus that fixed maximum overhead. It SHALL perform no eviction, large-value release, JSON encoding, content traversal, SQLite, MainActor wait, task per Event, or network mutation. At most one serial projection drain plus one dirty successor SHALL maintain an O(1) deque/exact-key index retaining at most 512 Events and 32 MiB, which can retain one maximum legal journal Event. Displaced values SHALL release outside the state lock. Deterministic bytes SHALL be documented as accounting, not actual Swift heap; callback latency and heap high-water SHALL be measured.

The projection SHALL also retain at most 16 frozen session metadata rows, exact later terminal disposition per retained Event, one positive-drop/cumulative sample per device, session end, live overflow/conflict gap, and store unavailable/recovery gap state. The process store SHALL publish content-free accepted/identical/journal-conflict/unavailable/recovered transitions to the projection executor without calling into protocol state or changing committed observations. Accepted SHALL wait for exact durable-row visibility before reconciliation; identical SHALL remove only the later exact transient candidate; journal-conflict SHALL remove that candidate and add its bounded marker so neither obscures the first durable row. Its latest-only UI wake SHALL run no more than once per main run-loop turn and 10 times per second, with at most one refresh query per cadence and none while presentation is paused. Runtime shutdown SHALL join ingress/drain work and clear every Event/session projection value before the existing cleanup receipt completes.

Its identity SHALL be `(runtime logical ID, connection ID, direction, wire sequence)`. Peer Event UUID SHALL remain content. Duplicate equivalence SHALL use the same durable projection in live and store: Event ID/type, canonical content JSON bytes, App-created time normalized once to nearest integer milliseconds since 1970, App monotonic time, priority, TTL, schema version, correlation/reply IDs, and initial disposition. Source/target/session epoch SHALL be validated against the exact session before commit, so a mismatch cannot reach a journal comparator. Frozen session metadata, deterministic byte accounting, and newly sampled Viewer receive times SHALL be excluded; the first accounting/receive values remain authoritative, and no hash alone decides equality. The composite journal SHALL linearize classification at live ingress before fan-out. While the key remains pending or retained, an identical duplicate SHALL be idempotent and conflicting content SHALL preserve the first observation, add one exact-key `presentationConflict` marker, and bypass store fan-out. Ingress rejection of a new key SHALL record the saturating gap and return `untracked`, after which the serial writer remains the only durable duplicate authority; if storage is unavailable too, no content or duplicate guarantee is retained. Eviction SHALL end that live duplicate horizon and SHALL already produce an overflow marker; no unbounded key tombstone SHALL be retained. A later candidate MAY become the new transient first after eviction. If an immutable durable row exists, the writer SHALL be the second authority: identical SHALL be a no-op and conflicting content SHALL preserve the row and return content-free `journalConflict` without making storage unavailable. If neither bounded live nor durable state retains the first observation, no post-eviction first-wins claim SHALL be made. Conflict markers SHALL coalesce only while resident and otherwise increment the saturating diagnostic-loss counter. Presentation may reconcile an exact key with a durable row but SHALL NOT backfill SQLite, infer acknowledgement, alter sequence/queue/token/terminal state, or keep transient content after runtime end.

One immutable projection snapshot SHALL drive live filtering/detail without consulting mutable session state. Runtime gaps apply to every retained Event; device gaps and positive drops apply to the exact device; terminal disposition applies to the exact Event; unavailable projection data does not match. Evaluation SHALL scan at most 512 entries/32 MiB, perform at most 16,384 predicate checks and 1,000,000 JSON-node visits, run at most 100 ms, check cancellation between entries/predicates/path components, and publish no partial result as complete. FTS5 full-text SHALL exclude transient rows with fixed recorded-data guidance rather than guessed tokenizer semantics.

The session manager SHALL accept one immutable prepared Event plus 1 through 16 manager-issued opaque target capabilities carrying random token UUID, exact runtime logical ID, manager generation, and connection ID. Capabilities SHALL be memory-only, non-reconstructible by UI, and limited to the exact active/terminal-cache lifetime below. The prepared value SHALL contain the one validated/encoded draft, checked accounted bytes, and normal or event-type-keyed keep-latest policy; no target admission may re-encode, deep-traverse, or deep-copy content. Duplicate token UUID occurrences SHALL all be invalid before admission and unique results SHALL preserve input order.

Classification SHALL be authoritative inside manager/session ownership. At most 16 active capabilities exist. Terminal moves the exact capability into a separate connection-keyed cache capped at 64 entries and retained while elapsed monotonic time is less than 30 seconds; equality expires, and capacity eviction uses oldest terminal time then token UUID lexical order. Same-route reconnect issues a new capability and never removes or satisfies the old entry. Shutdown/full identity reset clears the cache; it is not the route-keyed recent-device presentation. Malformed, duplicate, wrong-runtime, wrong-generation, never-issued, expired, capacity-evicted, or reset-cleared capabilities are `invalidTarget`. On the manager's serial executor, terminal-before-capability-lookup finds the exact terminal entry and is `noLongerConnected`; lookup-before-terminal followed by negotiating/disconnecting state or terminal-before-session-active-check is `notActive`; `queueRejected` requires exact active ownership with negotiated-size or bounded-queue rejection; and `queued` requires that exact session to buffer the prepared draft. Terminal after buffering does not rewrite `queued`. There SHALL be no retry, route retarget, cross-device rollback, secure-mailbox/peer claim, or independent send history.

#### Scenario: Storage is unavailable while uplink Events commit

- **WHEN** valid contiguous Events commit protocol sequence but cannot become durable rows
- **THEN** the bounded current-runtime window may present them as transient `Not recorded` rows
- **AND** store failure changes no connection, sequence, queue, token, timeout, or terminal decision

#### Scenario: Live callback ingress or window reaches a bound

- **WHEN** callback ingress would exceed 64 entries/20 MiB or projection would exceed 512 entries/32 MiB
- **THEN** callback admission remains constant-work, one saturating gap records rejected/displaced presentation values, and projection eviction occurs only on its executor
- **AND** no producer blocks, no Event is released under the callback lock, and no task/value accumulates per loss

#### Scenario: One selected target is no longer active

- **WHEN** a validated multi-target control draft reaches a target whose exact connection lost active ownership
- **THEN** that target receives `noLongerConnected` or `notActive` while other targets decide independently
- **AND** no new session is selected by route similarity and no delivery claim is made

#### Scenario: Same live key arrives with conflicting content

- **WHEN** a second observation reuses runtime/connection/direction/sequence with different Event content while the first key remains live or durable
- **THEN** the retained first Event remains, one bounded presentation-conflict marker is coalesced, and the duplicate does not replace it or make storage unavailable
- **AND** no durable or protocol outcome is changed

#### Scenario: Conflicting key returns after transient eviction during storage outage

- **WHEN** the first key was evicted, no durable row exists, and a later candidate reuses that key
- **THEN** the existing overflow diagnostic discloses the lost horizon and the later candidate may become the new bounded transient first
- **AND** no unbounded tombstone, global first-wins claim, or protocol mutation is introduced
