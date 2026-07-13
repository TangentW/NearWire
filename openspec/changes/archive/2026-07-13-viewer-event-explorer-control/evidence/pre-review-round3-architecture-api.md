# Pre-Implementation Architecture/API Review — Round 3

## Verdict

**Not approved for implementation.** The round-2 remediation closes the prior source-scope,
duplicate-horizon, control-capability, stale-scenario, renderer, cleanup, and evidence gaps, but two
actionable architecture/API findings remain. Approval requires artifact corrections and a fresh
independent review with zero unresolved findings.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 1 |
| Medium | 1 |
| Low | 0 |
| **Total actionable** | **2** |

## Scope and Method

This review independently reread the latest proposal, design, task plan, all three delta specs, all
round-1 and round-2 review reports, and both remediation notes, including the appended round-2
self-audit clarification. The remediation notes were treated as finding indexes, not approval
evidence.

Implementability was checked against the current Viewer application/runtime dependency seam,
session manager and session executor, journal/store pipeline, schema and SQLite pool, runtime reopen
state, query traversal/lease registry, export service, and current Event/device materialization. The
Xcode macOS SDK's system SQLite contract was also checked for the migration temporary-directory
requirement. No production or test source was modified.

The generic review skill's referenced `checklist.md` remains absent from the installed skill. The
repository-specific OpenSpec and AGENTS artifact-review gates were completed directly.

## Prior Architecture Finding Disposition

| Finding | Round-3 disposition | Independent verification |
| --- | --- | --- |
| A1 — Runtime-scoped component ownership | Resolved | One per-runtime factory now supplies the exact runtime ID, manager, handoff owner, typed control facade, live projection, composite journal, explorer inputs, and cleanup receipt; the process store stays outside and no downcast remains in the planned boundary. |
| A2 — Coordinator-generation store ownership | Resolved | `ViewerStoreRuntime` owns the gateway; operations carry coordinator generation and exact operation/lease identity; retirement seals, cancels, joins, releases against the originating registry, and closes before replacement publication. |
| A3 — Query arbiter and exact lease ownership | Resolved | One non-MainActor arbiter exclusively owns traversal refresh and exact reader tokens. Filtered export now freezes an immutable scope and uses the export reader's independent finite lease. |
| A4 — Complete bounded live state | Resolved for state ownership | Shared observations, later dispositions, session metadata, drops, gaps, immutable snapshots, fixed ingress/window bounds, and cleanup are explicit. R3-A2 is a new cross-authority equality mismatch, not the original missing-state issue. |
| A5 — Total presentation retention | Resolved | Recording, device, Event, gap, cursor/anchor, selection, detail, renderer, and accessibility residency and eviction behavior are bounded. |
| A6 — Closed downlink admission API | Resolved | Manager-issued opaque capabilities, a separate exact terminal cache, deterministic lifetime/eviction, manager-serial classification, and terminal-before-lookup/session-check/enqueue ordering now form a closed implementable API. |
| R2-1 — Stale activity catalog key | Resolved | The normative catalog scenario now uses immutable descending recording row ID inside one unchanged frozen traversal and explicitly restarts after relevant mutation. |
| R2-2 — Traversal-owned filtered export | Resolved | The normative export scenario now gives the arbiter scope-freeze ownership and the dedicated export reader an independent export lease. |

## Required Topic Verification

### Source-neutral explorer scope and materialization

The revised contract is implementable. `ViewerExplorerScope` can preserve current runtime and
connection logical IDs without manufacturing SQLite IDs. Current `Recordings.logicalID` already
accepts the runtime ID, `DeviceSessions.logicalID` can receive the admission connection ID through
the existing `beginDeviceSession(logicalID:)` seam, and store status/change publication can be
extended with an immutable row-ID materialization snapshot. Partial device materialization is
closed: live matching retains every logical selection, SQL receives only mapped selected devices,
and no durable query is issued when none is mapped. The generation replacement rule prevents a
mixed old/new traversal.

### Duplicate linearization, horizon, and store-result path

The new live-ingress decision is otherwise implementable. The exact-key index is the first bounded
classification point; retained identical/conflicting values do not fan out twice; `untracked`
values still enter the serial writer; eviction deliberately ends the live horizon; and the writer
can return content-free accepted/identical/conflict outcomes without changing protocol ownership.
The remaining field-set contradiction is R3-A2.

### Opaque targets and terminal cache

The current manager already has one ownership lock, at most 16 entries, exact connection IDs, a
terminal callback, and bounded route-recent state. It can add a distinct capability map/cache and a
serial classification executor without reusing the route-recent rows. The revised ordering defines
all races: terminal before capability lookup is `noLongerConnected`; lookup first followed by a
non-active session or terminal before the session check is `notActive`; committed enqueue stays
`queued`. No route lookup or reconstructed UI token is needed.

### Schema migration executor and status boundary

The off-MainActor writer-only state machine, exact token, one automatic attempt, explicit retry,
closed safe phases, rollback, final in-transaction probes, and reader-unavailable boundary can be
added around the current pool construction and runtime status signal. The dedicated migration temp
location is not safely specified; see R3-A1.

### Query and export ownership

The current coordinator-owned query/export services and value lease explain why the new runtime
gateway and arbiter are necessary, but do not block them. The gateway can retain originating
coordinator leases internally; an exact active-token check can guard `sqlite3_interrupt`; and an
immutable filtered-export scope can carry query plus upper bounds to the existing export reader,
which already owns a separate export lease, cancellation generation, bounded pages, and atomic file
commit.

## Actionable Findings

### R3-A1 — High — The dedicated migration temp directory requires an unspecified process-global SQLite mutation or a new scoped VFS

**Confidence: 10/10.** Design decision 11 and the modified local-store requirement require the
schema-1 writer to place SQLite disk-backed sort files in a migration-only Application Support
directory and remove that directory after success, cancellation, or rollback. The current
`ViewerSQLiteConnection` opens the system default VFS and configures `PRAGMA temp_store=MEMORY`; it
has no connection-scoped temporary-file location seam.

The system SQLite API does not provide a safe connection-local directory switch. The Xcode macOS
SDK header at `sqlite3.h:6740-6754` strongly discourages `sqlite3_temp_directory`, identifies it as a
process-global legacy variable, states that concurrent access is unsafe, and says it is intended to
be set once before any SQLite call and remain unchanged. The same header states that
`PRAGMA temp_store_directory` mutates that global. Setting it after opening the writer and restoring
or removing its directory after migration therefore violates the API lifetime contract and can
redirect or break unrelated SQLite users in the Viewer process. Setting `TMPDIR`/`SQLITE_TMPDIR`
dynamically has the same process-wide ownership problem.

A Viewer-owned scoped VFS could route only the migration connection's temporary opens through a
prevalidated directory, but that is a new security-critical filesystem/API boundary, not an
implementation detail already covered by the artifacts. It needs exact path-resolution, open-flag,
file-mode, delete-on-close, delegation, registration/unregistration, concurrency, and failure
semantics.

**Required artifact changes:** Choose and specify one safe strategy before implementation:

1. Define a Viewer-owned migration-only VFS wrapper, pass its unique name to the migration writer,
   route only the intended SQLite temporary-file class through an owner-only nonsymlink directory,
   delegate all other operations to the system VFS, and define finite registration and cleanup; or
2. Relax the dedicated Application Support location and allow SQLite's system-selected temporary
   location under an explicit security/resource contract.

In either case, explicitly prohibit runtime mutation of `sqlite3_temp_directory`,
`PRAGMA temp_store_directory`, `TMPDIR`, or `SQLITE_TMPDIR`. Extend tasks/tests with an unrelated
concurrent system-SQLite connection, migration success/cancel/failure, path replacement/symlink
races, exact file ownership, no process-global setting change, and cleanup after the last scoped
handle closes.

### R3-A2 — Medium — Live and durable duplicate authorities use different normative equality fields

**Confidence: 9/10.** The multi-device delta and design define duplicate equality as the complete
canonical Event envelope/content, initial disposition, **and frozen session metadata**, excluding
only newly sampled Viewer receive times. The modified local-store requirement defines an existing
durable row as identical when the complete Event envelope/content and initial disposition match;
it does not include frozen metadata. It then requires that match to be an idempotent no-op.

Those definitions disagree after the bounded live key is evicted or an ingress value is
`untracked`, when the writer is the only authority. A later observation with the same Event and
initial disposition but different frozen metadata is a conflict under the live definition and an
identical no-op under the store definition. The current store seam reinforces the ambiguity: the
duplicate query compares Event fields, currently including receive times, while disposition and
device/session metadata live in separate rows. Source changes can correct the current receive-time
behavior, but the artifacts must first define one comparison domain.

**Required artifact changes:** Define one exact internal duplicate-comparison value used by both
authorities and enumerate every field once. If frozen metadata is comparison-significant after the
live horizon, amend the store requirement and identify the immutable durable representation used to
compare the original metadata. If it is presentation-only, remove it from duplicate equality while
retaining it in the observation. Add before/after-drain, eviction, `untracked`, durable, and recovery
tests where Event/disposition match but one metadata field differs, and require the same typed
outcome and conflict-marker behavior from both authorities.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  — exit 0; `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` — exit 0 with no output after this report was added.
- Local system-SQLite capability check confirmed `TEMP_STORE=1` and that
  `PRAGMA temp_store_directory` is available, but the SDK contract above makes its process-global
  mutation unsuitable for the required migration-only lifetime.

No production source, test source, or artifact other than this review report was modified by this
review.
