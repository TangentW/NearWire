# Pre-Implementation Architecture/API Review

## Verdict

**Not approved.** The artifacts have **4 unresolved actionable findings**: 3 high priority and 1 medium priority.

The repository boundary is otherwise sound: SQLite, persistence, query, export, and storage presentation remain Viewer-internal; no Core/SDK persistence API or runtime dependency is introduced; the later event-explorer/control UI remains explicitly out of scope. The corrected `viewer-multidevice-flow-control` delta now modifies the exact canonical telemetry requirement and adds the journal seam separately.

## Findings

### 1. High — Durable lifecycle requirements contradict the fail-open store boundary

The design permits listener startup when the database cannot open, migrate, or satisfy its required features (`design.md`, Decisions 1 and 4), while the capability spec unconditionally requires every live runtime to create a recording-session row and every accepted connection to create exactly one linked device-session row (`specs/viewer-local-store-search/spec.md`, lines 19–32). Those guarantees cannot both hold when storage is unavailable, especially if a retry succeeds after devices have already connected or after the runtime has ended. The current shutdown text also assumes a durable parent/child order without defining what exists when the parent observation was never persisted.

Before implementation, define one coherent lifecycle contract. The recommended model is:

- create a stable in-memory recording identity before listener handoff, independent of database availability;
- state explicitly whether “exactly one row” is conditional on successful durable admission, or require retry to materialize the original parent and bounded retained child lifecycle before any later Event rows;
- define how a retry during the same runtime represents the unavailable interval (including devices that connected and ended during it) without inventing Events that were not retained;
- require causal ingress/write ordering so a recording row commits before its device rows, and a device row before its Event/sample rows; and
- add scenarios for unavailable-at-start, successful mid-runtime retry, unavailable-through-shutdown, and retry after an accepted connection already ended.

### 2. High — The single-connection executor does not yet support cancellable queries or exact streaming export

The design confines SQLite connection and statement ownership to one serial store executor (`design.md`, Decision 1), requires query cancellation to interrupt that connection (Decision 6), and allows an export of millions of rows from a read transaction or bounded read pages (Decision 7). This leaves two incompatible choices:

- a long read transaction on the sole executor blocks finite journal writes and maintenance; calling `sqlite3_interrupt` through that same executor cannot interrupt the currently running operation; or
- independent bounded page reads allow writes to proceed, but an upper row-ID bound excludes only later inserts and does not protect the frozen result from cleanup, manual deletion, rename/annotation changes, or other mutations between pages.

A second read connection can preserve a SQLite snapshot while WAL writes continue, but then a long export can retain WAL indefinitely and must have explicit ownership, scheduling, and quota behavior. A connection-wide interrupt also needs operation/generation binding so cancellation cannot affect an unrelated write or a subsequent query.

Before implementation, choose and specify a complete read-side model. It must identify connection/executor ownership, how cancellation reaches only the intended active operation, whether normal pagination promises only insert stability or a full database snapshot, how export preserves the exact frozen result across all source mutations, how cleanup/manual deletion coordinate with an active traversal/export, and how a long read bounds writer starvation and WAL growth. Add tests for cancellation racing query completion and a following write, cleanup/manual deletion during pagination/export, and sustained writes during a large export.

### 3. High — Capacity cleanup cannot compute the specified 85% physical low-water mark inside one deletion transaction

The artifacts define quota usage as live database pages plus current WAL bytes, require one immediate deletion transaction to select sessions until that usage is at or below 85% of capacity, and defer checkpoint/free-page reclamation until after commit (`design.md`, Decision 5; `specs/viewer-local-store-search/spec.md`, lines 90–109). In WAL mode, deleting rows writes additional WAL frames, while the current WAL file generally cannot shrink until a later checkpoint. Therefore the physical usage metric used by the requirement may remain unchanged or grow inside the transaction even when large logical sessions are deleted. Per-session logical counters are described only as estimates, so they cannot currently prove the exact low-water selection either.

Before implementation, define a computable selection and completion rule. For example, distinguish a trusted transaction-visible logical reclamation estimate from the separately reported physical footprint, then checkpoint and re-evaluate physical usage with a bounded follow-up policy; alternatively define a bounded pre-checkpoint/selection/post-checkpoint algorithm. Preserve atomic whole-session deletion, but specify what happens when physical usage remains above capacity after all eligible sessions are deleted. Update the 85% scenario and tests to cover a large pre-existing WAL, WAL growth caused by cleanup, checkpoint failure, and active/pinned data after eligible history is exhausted.

### 4. Medium — One immutable uplink observation cannot contain a final disposition before that disposition exists

The journal contract says one immutable observation is offered after frame validation/sequence commit and contains each record's final local outcome: offered, expired, overflow-dropped, or displaced (`design.md`, Decision 3; `specs/viewer-local-store-search/spec.md`, lines 34–44). A valid record that enters the bounded uplink queue can later expire, be displaced by a future enqueue, be handed to the consumer, or be removed during terminal cleanup. Its final outcome is not necessarily known when the frame commits, and terminal removal is not represented by the listed dispositions.

Before implementation, define the journal state machine. Either emit a committed logical Event observation followed by one idempotent terminal-disposition update, or emit the single Event observation only when the queue outcome becomes terminal while retaining the exact committed record under the existing queue bounds. In either model, specify terminal-cleanup disposition, idempotency/correlation keys, ordering relative to drop samples, and behavior when the journal cannot admit the later transition. Add scenarios for a queued Event later displaced, later expired, delivered, and removed by session termination.

## Approval Gate

Approval requires updating proposal/design/spec/tasks as needed, rerunning strict OpenSpec validation, and obtaining a fresh architecture/API review with **0 unresolved findings**.
