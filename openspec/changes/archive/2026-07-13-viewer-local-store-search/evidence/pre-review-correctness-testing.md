# Pre-Implementation Review — Correctness and Testing

Date: 2026-07-13

## Scope

Reviewed `AGENTS.md` and every current artifact and evidence file in the active `viewer-local-store-search` change. This review focused on lifecycle ownership, protocol-to-journal commit points, ingress and transaction bounds, retention/capacity cleanup, rollback and recovery, query Boolean semantics, frozen keyset pagination, export snapshots, and proportional test evidence.

The corrected `viewer-multidevice-flow-control` delta now modifies the canonical `Drop reporting and telemetry are bounded and content-free` requirement and adds the journal-observation requirement separately. Strict OpenSpec validation passes. No production or test source was modified; this report is the only added file.

Priority meanings:

- **P1 / Medium:** a contract gap that can produce incorrect durable history, over-delete data, violate a hard bound, or make a required scenario impossible. It must be resolved before implementation.
- **P2 / Medium:** a bounded but material snapshot/lifecycle ambiguity that will otherwise force incompatible implementations or incomplete tests.

## Findings

### NW-LSS-CT-PRE-001 — P1 / Medium — Uplink rows cannot have a final local disposition at the stated commit point

The artifacts require one uplink journal observation immediately after frame-wide validation and sequence commit, and say that each record already contains its final local result: offered to the consumer, expired, overflow-dropped, or displaced by overflow (`design.md:61-71`; `specs/viewer-local-store-search/spec.md:34-44`). That is not a total state machine.

At sequence commit, a valid Event may only be buffered in the live uplink queue. It can later be offered, expire at its exact receiver deadline, be displaced by a later priority overflow, or be cleared when the connection terminates. A later enqueue can also displace an older Event whose row was already journaled. Therefore the required “final” disposition is frequently unknowable when the one immutable commit observation is emitted.

This leaves incompatible implementation choices: store a premature disposition that becomes false, delay the Event row until a later outcome and lose immediate committed-traffic journaling, or mutate a row without any specified update observation, idempotency key, or transition rule.

**Required resolution:** define one exact durable disposition model. For example, insert a committed Event with a nonfinal `buffered`/`accepted` state and emit immutable outcome transitions keyed by recording, device connection, and Event ID; specify legal one-way transitions, duplicate handling, terminal clearing, and how an overflow victim from an earlier frame is updated. Alternatively, define the persisted disposition as the admission-time result only and stop describing it as final delivery/expiry. Update Tasks 3.3 and 7.2 with delayed delivery, later expiry, later overflow victim, terminal clear, duplicate transition, and failed-persistence cases that preserve sequence independence.

### NW-LSS-CT-PRE-002 — P1 / Medium — A legal observation can exceed the hard write quantum and the claimed quota overshoot

Store ingress permits 16 MiB by default and 64 MiB at its hard maximum, but one transaction is unconditionally capped at 4 MiB (`design.md:73-79`; `spec.md:57-73`). The preceding Viewer capability can negotiate a logical Event substantially larger than 4 MiB, up to its bounded Event limit. A complete immutable journal observation is larger than its content because accounting also includes metadata.

The artifacts do not say what happens when one valid observation is larger than 4 MiB. It cannot enter a conforming transaction without breaking the quantum, cannot be split into multiple independently visible Event rows without breaking transaction/FTS atomicity, and will retry forever if it remains at the ingress head. A maximum-size observation can also exceed the 16 MiB default ingress after metadata is added.

The related statement that physical capacity may overshoot by at most one 4 MiB batch is also not guaranteed by a 4 MiB logical-observation budget: SQLite page, index, FTS, and WAL amplification can consume more than the encoded observation bytes (`design.md:98`; Tasks 3.1 and 4.2).

**Required resolution:** define a maximum single journal-observation size and make it coherent with the ingress and transaction maxima. Choose either a bounded oversize-to-gap rule before ingress, a one-record transaction exception with a larger explicit hard bound, or a lower persistence Event limit. Define quota reservation in terms of a conservative physical upper bound or soften the physical overshoot guarantee. Add exact just-below/equal/above single-observation tests, head-of-line behavior, FTS rollback, ingress accounting, and physical-usage amplification evidence.

### NW-LSS-CT-PRE-003 — P1 / Medium — Bounded ingress can drop structural lifecycle observations and leave protected sessions permanently open

The change requires exactly one durable recording row and one exact device-session lifecycle per accepted connection, closed idempotently and ordered before recording closure (`design.md:42-59,137-141`; `spec.md:19-32,187-195`). At the same time, all journal observations appear to share the same bounded ingress, and ingress overflow, unavailable storage, capacity pause, and write failure convert rejected observations into a gap (`design.md:73-79`; `spec.md:57-73`). No capacity or priority is reserved for recording start/end or device start/terminal observations.

If Event observations fill ingress when a device terminates, its terminal observation can be reduced to a gap. The recording end can fail similarly. Durable rows then remain active/open even though runtime cleanup completed. Automatic maintenance is forbidden from deleting active recordings, so these rows can become permanently protected and eventually force capacity pause.

The same ambiguity exists when storage is unavailable before listening: the network may start, but the requirement still says the runtime creates a recording before transfer. No recovery rule explains how a later successful retry backfills the recording/device hierarchy before retained Events. A process crash or failed final flush can also leave previously committed active rows, and startup defines no orphan reconciliation.

**Required resolution:** separate structural lifecycle ownership from lossy Event journaling. Reserve a finite lifecycle/control allowance derived from the 16-session bound, or make the coordinator synthesize and commit lifecycle closure independently before Event drain. Define logical versus durable recording creation during unavailable startup, retry ordering, shutdown flush ordering, and startup reconciliation of rows left open by crash or failed final flush, using a closed recovered terminal category. Extend Tasks 3.1–3.3 and 7.2 with full-ingress terminal, unavailable-at-start then retry, failed recording-end flush, process-crash reopen, idempotent duplicate close, and zero permanently protected orphan tests.

### NW-LSS-CT-PRE-004 — P1 / Medium — The 85% cleanup target is not computable safely from live pages plus WAL inside one delete transaction

Quota decisions correctly reject peer-reported sizes and use live database pages plus WAL bytes. Cleanup must select and delete whole sessions in one immediate transaction until that usage reaches 85% of capacity, while checkpoint/free-page reclamation happens only after commit (`design.md:81-98`; `spec.md:90-109`).

Those rules do not define a stable selection metric. Relational deletion creates free pages and additional WAL frames; the WAL cannot be checkpointed away while the deleting transaction is still open. If current WAL bytes alone keep measured usage above the low-water mark, repeatedly deleting eligible sessions cannot satisfy the predicate inside that transaction and may select every eligible session unnecessarily. Conversely, per-session logical counters are explicitly not authoritative for quota decisions.

The resume rule is also incomplete when eligible deletion can return usage below capacity but not to 85% because the remaining data is protected: the scenario pauses only when protected data prevents return within capacity, while the cleanup algorithm names 85% as its target.

**Required resolution:** specify separate, overflow-safe metrics for selection and post-commit physical enforcement. Define whether selection uses `(page_count - freelist_count) * page_size`, a conservative per-session physical attribution, pre-cleanup checkpoint state, or another measurable value; define how WAL growth is reserved; define the exact result when eligible sessions are exhausted between 85% and 100%; and bound post-commit checkpoint failure without over-deleting. Add deterministic threshold tests at 85% and 100%, WAL-dominant usage, deletion-generated WAL, all-eligible exhaustion, protected-only usage, arithmetic overflow, rollback, and checkpoint failure.

### NW-LSS-CT-PRE-005 — P1 / Medium — An upper Event row ID does not provide the promised frozen pagination snapshot

The first page freezes only an upper Event row ID, while later pages run separate keyset queries (`design.md:102-117`; `spec.md:142-154`). This excludes later inserts only if Event row IDs are guaranteed never to be reused, which the schema decision does not state. More importantly, it cannot preserve the original matching set across cleanup or manual deletion. A recording session deleted between pages removes original rows, producing the exact omission the scenario forbids.

Query membership can also change without inserting a new Event row. Gap/drop-presence predicates depend on related tables that may receive later samples for an older recording. The same old Event row IDs can therefore begin or stop matching beneath an unchanged upper bound. Query fingerprint binding protects cursor misuse, not database revision changes.

A long-lived SQLite read transaction would provide a true snapshot, but an opaque cursor can be retained arbitrarily between UI requests; keeping that transaction open would retain WAL and executor resources without a defined bound. Materializing every matching ID is explicitly disallowed.

**Required resolution:** choose implementable traversal semantics. Options include a bounded snapshot lease with explicit expiry/resource ownership, a recording/store revision in the cursor that fails closed and requests refresh after any membership-changing deletion/update, or weaker documented semantics that guarantee no new Event inserts/duplicates among surviving rows but permit concurrent cleanup omissions. Require monotonic nonreused Event IDs if an upper ID remains part of the rule. Specify forward/backward inequalities and page reversal against `(viewerMonotonicNanoseconds, rowID)`. Update Tasks 5.2 and 7.3 with inserts, cleanup deletion, manual deletion, gap/drop mutation, equal monotonic timestamps, row-ID reuse prevention, cursor expiry/revision mismatch, and both traversal directions.

### NW-LSS-CT-PRE-006 — P2 / Medium — Export snapshot and alias ownership are not finite or atomic across all exported tables

Export captures the Event upper row ID and then streams from “a read transaction or bounded read page” (`design.md:119-127`; `spec.md:156-173`). Those are materially different consistency models. Bounded pages do not freeze session/device metadata, gaps, annotations, or deletions. One long read transaction freezes them, but exporting millions of live Events can retain WAL growth for an unbounded user-controlled duration and interfere with the same physical-capacity policy.

The export also prepares all deterministic device aliases in memory. A recording session can contain an unbounded number of sequential reconnect/device rows over a long runtime even though only 16 are live at once. Therefore “alias metadata” is not itself a memory bound for complete-session export. A filtered query has at most 16 selected devices, but complete-session export does not.

Cleanup/manual deletion, annotation edits, cancellation, and runtime writes are not assigned a winner against export. Without a lease or revision, the root `session`, `devices`, `events`, `gaps`, and `annotations` can come from different logical snapshots even if Events obey the upper row ID.

**Required resolution:** select one export snapshot mechanism and bound its lifetime and WAL/resource cost. Define whether export is limited to closed sessions, temporarily protects a session from cleanup/deletion, fails on revision change, or owns a bounded SQLite snapshot lease. Stream or externally index aliases, or impose an explicit device-row bound; do not retain an unbounded alias dictionary. Specify winners for cleanup, manual delete, annotation mutation, cancellation, and destination replacement. Extend Tasks 5.3 and 7.3 with concurrent insert/delete/annotation cases, many-device complete export, snapshot expiry/revision failure, WAL growth bound, cancellation at every file phase, directory flush/atomic replacement, and forbidden-field scans.

## Query Boolean Semantics and Test Proportionality

The current Boolean grouping is directionally sound: different dimensions use AND; selected values inside a dimension use OR; JSON predicates use AND; and one JSON predicate may contain an OR-list (`design.md:102-115`). Search and JSON input bounds and parameter-only SQL construction are also explicit.

Implementation should normalize a query before fingerprinting: set-valued selections need deterministic ordering/deduplication; JSON numeric values need one canonical representation; Event-type prefix/exact modes and traversal direction must be fingerprint inputs; and literal FTS quoting must define whether a multiword input is one phrase or several terms. These details can be completed while resolving Finding 5.

Task 7.3 should be interpreted proportionately. It does not need the Cartesian product of every filter value. A good plan is:

- compiler-level truth-table tests for every dimension's OR group and cross-dimension AND composition;
- representative pairwise database integrations across FTS, JSON, scope, and exact dimensions;
- adversarial validator/binding tests for all grammar and size boundaries;
- stateful pagination/export tests for the concurrency winners identified above.

Large-export memory can be proved with instrumented page/buffer/alias ownership and a moderate deterministic dataset rather than making ordinary CI generate millions of Events.

## Validation Observations

- `env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive`: passed; the change is structurally valid.
- `git diff --check`: passed.
- The scope respects repository boundaries: system SQLite is Viewer-only, with no proposed Core/SDK dependency, nested package manifest, server, or public SDK API.
- The task plan already includes broad SQLite rollback, failure injection, ingress, cleanup, query, export, lifecycle, UI, packaging, and documentation coverage. The findings above require sharper winner and boundary oracles, not a larger indiscriminate test count.

## Verified Strengths

- Persistence is explicitly observational and cannot become delivery acknowledgement or protocol authority.
- Invalid uplink frames and rejected downlink mailbox candidates have clear no-journal commit rules.
- Ingress count/byte bounds, one-drain ownership, finite transaction yielding, coalesced gaps, and nonpolling write failure are well motivated.
- Retention precedes capacity cleanup; automatic deletion is whole-session, pinned/active protected, and transactionally rolled back.
- SQL/FTS/JSON inputs use closed validation and bound values rather than raw identifiers or expressions.
- Export uses an owner-only sibling temporary and preserves an existing destination on failure.
- Safe status/UI scope and sensitive-data exclusions are clear, and signing/encryption non-goals are explicit.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 6 — 0 High, 6 Medium, 0 Low.**

The change has a strong scope and safety direction, but the six lifecycle, capacity, snapshot, and export boundaries above must be made internally consistent and testable before production or test implementation begins.
