# Pre-Implementation Correctness and Testing Review — Round 4

## Verdict

**Approved for implementation.** The current common artifact snapshot resolves every prior
correctness/testing finding and the later round-3 and round-4 cross-review issues. No unresolved
actionable correctness or testing finding remains.

| Severity | Unresolved count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| **Total actionable** | **0** |

This is artifact approval only. Implementation checkboxes still require their stated evidence, and
the completed implementation still requires tasks 7.1 through 7.3.

## Scope and Method

This review reread the current proposal, design, task plan, and all three delta specifications. It
also reread all round-1, round-2, and round-3 review reports; the round-1 through round-3 remediation
records; and the round-4 remediation record added while this review was running. Remediation text was
treated as a map of claims to verify against the normative artifacts, not as approval evidence.

The review replayed CT1 through CT7 and R2-CT1 through R2-CT4, then independently checked the later
migration-temp, duplicate-comparator, and clipboard findings. Implementability and deterministic
test seams were checked against the current query/compiler, Event duplicate lookup, store/runtime
connections, session manager/recent rows, Core Event limits, Viewer sandbox entitlement, and the
local macOS SDK's system SQLite contract.

The earlier round-3 correctness report approved an older snapshot and described session metadata as
duplicate-significant. That statement is superseded: the current artifacts deliberately retain
session metadata in the shared observation for presentation/filtering but exclude it from Event
duplicate equality.

## Prior Correctness Findings

| Finding | Current disposition | Verification |
| --- | --- | --- |
| CT1 — Query cancellation and lease ownership | Resolved | The runtime gateway binds operations and leases to the originating coordinator generation. One non-MainActor arbiter solely owns traversal refresh; enqueue-to-completion tokens make cancellation successor-safe; filtered export receives an immutable scope and independent export lease. Tasks 2.2, 2.3, 6.1, 6.6, and 6.7 cover the exact races and releases. |
| CT2 — Store/live filter oracle and exact-key behavior | Resolved | One normalized observation supplies the same receive times, identity, Event, disposition, and bounded metadata to both paths. Presence scopes, unavailable behavior, durable-only FTS, differential predicates, duplicate equality, and the bounded authority horizon are closed and tested. |
| CT3 — Frozen catalog membership/order | Resolved | Recording pages use immutable descending row ID; device pages use connection ordinal plus row ID. Cursors bind immutable bounds/generations/fingerprint and relevant mutation explicitly restarts traversal. |
| CT4 — Gap membership/placement | Resolved | Gaps use a separate lane bound to exact traversal lease, device scope, and frozen gap upper row ID, with stable identity, latest revision, deterministic order, 32-row pages, 128-row residence, and bounded selected-device merge. |
| CT5 — Causality determinism | Resolved | Scope, upper bound, row-ID candidate/visited identity, reply-before-correlation breadth-first order, nine-row truncation probe, 32-node cap, index, work budget, and 0/1/2/8/9+ tests are explicit. |
| CT6 — Pause/shutdown generations | Resolved | Pause invalidates generation before freeze; source/filter/Pause/Resume/Jump share one state machine; stale traversal release is exact-once; runtime/attempt generations gate publication and admission; the finite cleanup receipt joins and clears every content-bearing producer/value. |
| CT7 — Target categories and races | Resolved | Opaque exact-connection capabilities, bounded active/terminal ownership, ordered duplicate handling, manager/session classification, terminal lookup ordering, and enqueue truthfulness form one closed API with the complete boundary/race matrix in task 6.4. |
| R2-CT1 — Source-neutral current-live query | Resolved | `ViewerExplorerScope` preserves exact runtime/device logical IDs without synthetic durable IDs. Partial materialization compiles only mapped selected devices, issues no durable query when none map, retains every live selection, and atomically replaces traversal when exact mappings appear. |
| R2-CT2 — Duplicate horizon/linearization | Resolved | Live ingress is the first bounded classifier; `untracked` still reaches the writer; eviction explicitly ends live authority; the durable row is the second authority; conflict markers and lost-horizon behavior are bounded; no global post-eviction claim remains. |
| R2-CT3 — Terminal capability cache | Resolved | The exact connection-keyed cache is distinct from route-recent presentation, capped at 64 and 30 seconds with equality expiry and deterministic time/UUID eviction; same-route reconnect cannot satisfy/remove an old capability; reset/shutdown clear it. |
| R2-CT4 — Stale scenarios | Resolved | The catalog scenario uses immutable descending row-ID continuation/restart, and filtered export uses an arbiter-frozen immutable scope plus an independent export-reader lease. |

## Round-4 Focused Verification

### Duplicate equality is identical at live ingress and durable storage

The comparator now has one exact domain in the design and both affected capability deltas:

- exact runtime/connection/direction/sequence is the journal identity;
- equality compares the complete canonical Event envelope/content and initial disposition;
- frozen session metadata is excluded because it is validated/owned by the session boundary;
- each later observation's newly sampled Viewer wall/monotonic receive times are excluded;
- the first observation's receive times remain authoritative; and
- field/byte comparison, not a hash alone, decides equality.

This removes the former live/store mismatch. It also directly requires replacing the current durable
lookup behavior, which compares Viewer receive timestamps and turns mismatches into store
corruption. Task 3.2 now repeats the exact comparator. Task 6.3 makes metadata-only and receive-time-
only changes remain identical, preserves the first receive time, makes Event/disposition changes
conflict, and forbids hash-only decisions across pending, drain, eviction, `untracked`, durable,
recovery, and shutdown states. It additionally asserts exact durable rows/status, live markers, and
callback/drain counts. The previous ambiguity is therefore a deterministic conformance failure, not
an implementation choice.

### System-default-VFS migration has a finite, testable connection lifecycle

The migration no longer attempts an unsafe connection-local directory override. It uses the system
default VFS and the process-provided sandbox/private temporary hierarchy only after verifying an
existing current-user-owned mode-`0700` nonsymlink root. NearWire neither reads nor mutates
`sqlite3_temp_directory`, its pragma, `SQLITE_TMPDIR`, or `TMPDIR`, and installs no custom VFS.

That direction matches the local SDK contract: `sqlite3.h` lines 6730 through 6769 describe
`sqlite3_temp_directory` as discouraged process-global legacy state that must not be changed around
concurrent connections; lines 1377 through 1422 define temporary opens and their
`SQLITE_OPEN_DELETEONCLOSE` lifecycle. The current Viewer is App Sandbox-enabled and its ordinary
SQLite path already uses the default VFS with per-connection `temp_store=MEMORY`, providing a
concrete normal-connection seam.

The connection transition is now exact:

1. a dedicated off-MainActor migration writer alone uses FILE temp and the 32-MiB migration cache;
2. query/export readers remain closed;
3. commit or rollback is followed by migration-writer close and join to zero sorter descriptors;
4. success opens a fresh normal writer with `temp_store=MEMORY` and an explicit 8-MiB cache;
5. that writer reprobes schema, hardening, features, indexes/plans, and connection settings;
6. two equally normal fresh readers open only after the writer probe; and
7. availability publishes only after all probes, while a post-open failure closes the fresh pool.

Thus FILE-temp and the migration cache cannot leak into runtime use. Task 6.1 requires exact
construction order, settings, close/join, sorter mode/content/descriptors, post-open probes, and
failure evidence.

### Database and temporary volumes are independently governed

Before the transaction, checked arithmetic requires both the database volume and the actual process
temporary volume—once when identical—to have at least
`512 MiB + 6 * allocated(main database + WAL + SHM)` free. Overflow, unsafe temporary root, or low
capacity starts no transaction. During SQLite work, the progress callback runs within each 10,000 VM
instructions and aborts if either volume falls below 256 MiB or the exact token is invalidated.

Task 6.1 explicitly requires distinct-volume near-capacity/overflow cases, unsafe/symlink/wrong-mode
temporary roots, unchanged global routing/default VFS, live sorter inspection, no Event content in
sorters, zero descriptors, cancellation/termination/rollback/retry, and post-schema probes. The
100,000-Event/10,000-gap fixture, 128-MiB measured heap-growth ceiling, 250-ms injected SQLite
cancellation acknowledgement, exact counters, and diagnostic-only total duration remain coherent.

### Terminal classification is closed at each ownership boundary

Classification remains on the manager's serial executor. A terminal transition that wins before
exact capability lookup moves/furnishes the retained terminal entry and returns
`noLongerConnected`. Lookup that first resolves the exact owned session, followed by a
negotiating/disconnecting state or terminal before the synchronous active check, returns
`notActive`. `queueRejected` requires exact active ownership and negotiated-size/bounded-queue
rejection. A committed buffer operation returns `queued` even if terminal follows immediately.

Expired, evicted, never-issued, wrong-runtime/generation, reset-cleared, malformed, and duplicate
capabilities remain `invalidTarget`; no path retries or retargets by route. Task 6.4 covers 64/65
entries, equal terminal times, the exact 30-second boundary, reconnect, all category/race states,
mixed 16-target order, superseding attempts, and shutdown admission.

### Operator input and received Event clipboard boundaries no longer conflict

Standard user-invoked copy/cut/paste is intentionally available only in operator-owned editable
composer, filter, and metadata controls. A paste replacement passes the same incremental byte/scalar
cap before model storage, including multibyte replacement and over-cap rejection. NearWire performs
no background pasteboard access, restoration, or custom history.

Received/stored Event inspector content exposes no copy, cut, drag, share, or clipboard-export
command. This is distinct from the mandatory disclosed Complete Recording/Current Filtered Result
JSON file-export workflow, which remains available under its independent lease and atomic-file
contract. Tasks 5.5 and 6.4 preserve that distinction and exercise the actual macOS text controls,
keyboard commands, and contextual commands rather than only the presentation model.

## Other Normative Consistency and Coverage

- Renderer preparation retains one canonical detail buffer and has independent raw/tree/log/table/
  numeric input, scan, derived-byte, row/node, preview, accessibility, logical-time, and cancellation
  bounds. Log object lookup is capped at 4,096 top-level entries; task 6.5 covers maximum/untrusted
  shapes, controls/bidirectional text, VoiceOver, cancellation, retention, and stale publication.
- Composer sizing uses checked nonnegative arithmetic against both active Core limits and the Viewer
  16-MiB model ceiling. TTL uses a nine-ASCII-digit `UInt64` editor within the active Core range.
  Task 6.4 covers content/model/queue boundaries, multibyte edits, overflow/range, and exactly one
  encode/traversal/copy.
- Catalog, timeline, gap, causality, renderer, export, live match, and composer completions all carry
  exact generations. Task 6.7 proves blocked cleanup, zero resident content/derived/accessibility
  buffers and subscriptions, exact lease release, redacted cancelled values, and no prior-runtime
  content after restart.
- Every normative count, byte, logical deadline, generation, token, VM step, page, cursor, wake, and
  lease is release-blocking under task 6.9. Machine wall time and whole-process heap remain diagnostic
  unless paired with the specified structural gates.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  exited 0 with `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` exited 0 with no output.
- Active-artifact scans found none of the superseded activity/row-ID catalog, traversal-owned export,
  session-metadata duplicate equality, migration-only Application Support temp routing, process-
  global temp mutation, blanket clipboard prohibition, or inspector/file-export conflation.
- `git status --short` showed only the active untracked OpenSpec change directory. No production or
  test source was modified by this review.

## Conclusion

There are **zero unresolved correctness/testing findings** in the current pre-implementation
artifact snapshot. This snapshot is approved for the correctness/testing dimension of task 1.2;
task 1.2 may complete only after the same current snapshot receives zero-finding approval in the
other required review dimensions.
