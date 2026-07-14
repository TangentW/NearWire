## ADDED Requirements

### Requirement: Store exposes bounded candidate-scanned performance and gap traversal

The Store explorer gateway SHALL expose one forward-only internal traversal for a positive recording
row ID, positive exact device-session row ID, inclusive Viewer monotonic lower/upper bounds, frozen
Event/gap upper row IDs, Store generation, and opaque continuation. The continuation SHALL bind the
complete scope and exact last examined `(viewerMonotonicNanoseconds, eventRowID)` independently of
the last emitted row. Results SHALL order stably by that key.

The accepted existing device timeline index SHALL scan candidate metadata before residual exact-type
filtering. Each examined matching or nonmatching candidate SHALL advance the continuation. A turn
SHALL examine at most 4,096 candidates and emit at most 512 carriers. SQLite SHALL read type and
`length(contentJSON)` before content. Content longer than 65,536 UTF-8 bytes SHALL emit only identity,
length, and invalid marker. Eligible content SHALL copy only while aggregate copied bytes remain at
most 4,194,304; every carrier SHALL charge 512 fixed bytes and the page wrapper 4,096, for a
4,460,544-byte page maximum. If the next eligible row would cross bytes, the turn SHALL stop before
examining it. A zero-match turn SHALL return its advanced continuation; no row may skip, duplicate,
or livelock.

An injected monotonic clock and VM counter SHALL gate 50 ms and 5,000,000 instructions. Cancellation
is checked before work. Equality after an examined row yields at that row. VM/time exhaustion before
the first candidate SHALL return terminal work-limit failure rather than an unchanged continuation.
Host elapsed time SHALL be diagnostic only. The query arbiter SHALL own the traversal and finite
lease; cancellation, mode/range/source replacement, Store retry/reopen, and cleanup SHALL release it
once and SHALL not interrupt or retarget a successor.

The same frozen scope SHALL expose gap pages of at most 32 latest-revision exact-device/recording-wide
rows under its gap upper row ID and at most 128 detailed gaps to one projection. Store SHALL normalize
each row into one fixed 256-byte carrier containing only row/scope identity, a closed safe kind,
schema-2 Viewer wall interval, and applicability. Variable namespace, reason, and direction strings
SHALL not cross. A fixed 512-byte wrapper SHALL carry generic `hasMoreRows`, a saturating
performance-or-uncertain count, and `hasMoreApplicableGaps`, making each page at most 8,704 bytes.

Store SHALL classify the complete frozen matching gap metadata scope before deciding applicable
overflow, under the existing 2,000,000-VM-step, injected-250-ms, cancellation, and accepted-plan
gates. A hidden performance or uncertain row SHALL set `hasMoreApplicableGaps`; hidden irrelevant-only
rows SHALL set only `hasMoreRows`. If complete classification exhausts its budget, the returned page
SHALL set `hasMoreApplicableGaps` true regardless of its partial count, never claim classification
complete, and never reconnect a line. Store SHALL not fabricate monotonic time.

Normalization SHALL use case-sensitive ASCII exact/prefix comparison and map
`missingInitialEvent.*` to eventLoss; `storageUnavailable`,
`midRuntimeRetry`, `liveStart`, and `store*` to storageContinuity; `uplinkDisposition*`,
`dropJournal*`, and `policyJournal*` to controlContinuity; `deviceClose*` and `shutdownStructural*` to
lifecycleContinuity; and `coalescedOverflow` or unrecognized reasons to unknown. Direction SHALL map
`appToViewer`/`both` to performance, `viewerToApp` to irrelevant, and `unknown` or unrecognized input
to uncertain. Unknown kind or applicability SHALL remain conservative rather than being discarded.

Schema version SHALL remain 2. No performance table, derived JSON, trigger, index, database,
background backfill, or migration SHALL be added. Raw Events and gaps remain subject to existing
quota, retention, pin, deletion, export, secure-file, and cleanup behavior.

#### Scenario: Ordinary Events precede a matching snapshot

- **WHEN** 4,097 nonmatching Events precede one matching performance Event
- **THEN** the first empty turn advances exactly 4,096 examined keys and the next turn emits the snapshot once
- **AND** no returned-row cursor, time/VM boundary, or continuation retry can skip or duplicate it

#### Scenario: Aggregate page bytes fill

- **WHEN** the next at-most-65,536-byte snapshot would cross 4,194,304 copied content bytes
- **THEN** the page ends before examining it and the next page retries it under the same scope
- **AND** an oversized row returns only bounded metadata while raw JSON remains in Events

#### Scenario: Store generation changes between turns

- **WHEN** generation A attempts another turn after generation B is published
- **THEN** A is rejected and its exact traversal/lease is released once
- **AND** only an explicit fresh request may use B

#### Scenario: Generic pagination hides different applicability tails

- **WHEN** two 129-row scopes retain identical 128 irrelevant carriers but only one hidden tail is performance-applicable
- **THEN** both report `hasMoreRows` while only the applicable-tail receipt reports `hasMoreApplicableGaps`
- **AND** a classification budget failure cannot report the hidden tail as irrelevant-only
