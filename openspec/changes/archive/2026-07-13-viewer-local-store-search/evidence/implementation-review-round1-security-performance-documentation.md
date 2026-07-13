# Implementation Review Round 1 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This independent review compares the current uncommitted `viewer-local-store-search` implementation, tests, application integration, and operator documentation with the active proposal, design, capability deltas, and task plan. Production and test source were inspected but not modified.

The review focused on SQLite hardening, path and file protection, SQL/FTS/JSON input boundaries, sensitive-value leakage and reflection, bounded memory/disk/task/WAL work, quota and cleanup correctness, export safety and disclosure, privacy-manifest/documentation evidence, and isolation of protocol queues from storage.

## Verdict

**Not approved.** Ten actionable findings remain: six high and four medium. The implementation establishes useful foundations, but several security and boundedness claims in the approved artifacts are currently documentation-only or are contradicted by production behavior.

## Findings

### NW-ISPD-001 — High — Protocol callbacks still perform synchronous lifecycle SQLite and create an unbounded preparation-task queue

The persistence seam is not constant-bounded. Session admission calls `journal.sessionStarted` synchronously before `session.start()` (`ViewerMultiDeviceSessionManager.swift:138-145`); the coordinator then performs recording/device SQLite transactions while holding its lock (`ViewerStoreCoordinator.swift:86-103`). Terminal delivery synchronously triggers a maintenance campaign of up to eight SQLite turns (`ViewerStoreCoordinator.swift:131-157`). Uplink/downlink content preparation has been moved off the protocol executor, but each callback submits a fresh closure containing the Event or whole envelope array to an unbounded serial `DispatchQueue` before the bounded ingress owns it (`ViewerStoreCoordinator.swift:48`, `106-129`, `160-188`). A burst can therefore retain unbounded Events/tasks outside the 4,096/32-MiB ingress. Downlink journaling is invoked on the session path immediately after mailbox commit (`ViewerMultiDeviceSession.swift:829-843`), so it can enqueue that unbounded work directly. Busy timeout and maintenance can still delay connection start or terminal cleanup, while preparation backlog can grow independently of configured store bounds.

Required remediation:

- Make every protocol-facing journal offer an O(1) bounded reservation directly into a count/byte-capped owner using the wire layer's already-computed size and copy-on-write record ownership; do not create one unbounded dispatch closure per record/frame.
- Move canonical JSON, SQLite lifecycle admission, maintenance, retry, and every linear content operation behind that bounded owner.
- Do not hold coordinator locks across SQLite calls.
- Add maximum Event/batch and injected slow/busy SQLite tests that measure the protocol callback and prove sequence, mailbox, token, timeout, and terminal progress remain unaffected.

### NW-ISPD-002 — High — Ingress drops admitted work, creates per-loss values, and has no finite shutdown flush

The drain copies/removes a batch from the bounded arrays before any database commit (`ViewerEventStore.swift:659-681`). On the first write failure it returns without restoring the prefix, coalescing a gap, or retaining an explicit retry boundary (`ViewerEventStore.swift:695-703`). The current snapshot correctly writes each selected batch through `appendEvents`, but `removeFirst` and `Array(prefix)` still perform work proportional to queue size while producers share the same lock. Overflow calls create a new structural gap and sequence for each lost Event (`ViewerStoreCoordinator.swift:122-127`, `238-256`) rather than one saturating aggregate; those values can fill the 36-entry structural lane and are silently ignored. Shutdown calls `stop()`, which immediately deletes every accepted Event and structural close (`ViewerStoreCoordinator.swift:190-203`; `ViewerEventStore.swift:641-647`) instead of owning one finite final flush.

Required remediation:

- Keep the transaction prefix owned until commit; on failure restore the exact bounded prefix once, transition to `writeFailed`, and stop automatic retry.
- Use a deque/ring or indexed buffer so admission and drain do not shift/copy the queue under the producer lock.
- Persist actual 256-record/4-MiB batches and the single-record oversize path atomically.
- Replace per-loss structural values with one saturating per-recording aggregate and preserve lifecycle capacity.
- Implement and test the specified finite shutdown flush/cleanup receipt rather than clearing accepted work.

### NW-ISPD-003 — High — Tombstoning does not subtract visible quota and capacity selection can over-delete

Maintenance selects only each recording base row's `quotaBytes`, not its complete schema-owned recording attribution (`ViewerStoreMaintenance.swift:264-286`). The selection condition uses the unchanged global quota as a constant and takes up to 32 candidates without subtracting candidates until the 85% target is reached. Committing tombstones then **adds** tombstone quota (`ViewerStoreMaintenance.swift:289-307`) rather than atomically removing the selected recording's exact visible quota. Manual deletion does the same (`ViewerStoreMaintenance.swift:233-256`). This can tombstone more recordings than necessary, leave logical usage above capacity until later physical deletion, and make `capacityPaused` recovery disagree with visible history. In addition, the 64-MiB filesystem safety check is used only before checkpoint and fails open to `Int64.max` when the capacity API errors (`ViewerStoreMaintenance.swift:430-447`); Event writes perform no pre-transaction volume check (`ViewerEventStore.swift:428-445`).

Required remediation:

- Maintain an exact per-recording schema counter and subtract the complete selected visible quota in the tombstone transaction.
- Select retention candidates first, then capacity candidates only until the checked projected total reaches 85% or the turn bound.
- Treat failed volume-capacity inspection as a closed safe pause, and apply the physical safety reservation before every write/reclaim transaction, including oversize mode.
- Add exact 85%/100%, overflow, protected/leased, checkpoint failure, and disk-space failure evidence proving no over-delete or false resume.

### NW-ISPD-004 — High — Physical reclaim contains an unbounded metadata tail and retains raw global aliases

Event deletion is bounded initially, and the current snapshot correctly excludes a tombstone after marking an impossible head. However, after Events are exhausted `deleteEmptyRecording` deletes every policy, drop, device-version, gap, annotation, recording-version, and device row for the recording in one transaction (`ViewerStoreMaintenance.swift:380-418`). A long recording can therefore create an unbounded writer/WAL turn despite the 1,024-row/4-MiB contract. Raw installation identifiers are global rather than recording-local (`ViewerStoreSchema.swift:94-99`), are never reclaimed by `deleteEmptyRecording`, and retain their quota and correlation data after all recordings are deleted.

Required remediation:

- Reclaim every child/version/sample/alias/FTS class through the same finite row/byte quantum before deleting the parent/tombstone.
- Scope installation aliases to a recording, reclaim them, and prove raw identifiers disappear when their recording is physically removed.
- Add huge non-Event metadata, repeated reconnect, WAL, rollback, and sensitive-remnant tests; retain an impossible-head-followed-by-valid-tombstone regression test for the new isolation behavior.

### NW-ISPD-005 — High — Query pages can allocate gigabytes and do not enforce their snapshot/scope contract

`ViewerStoredEventRow` contains full `contentJSON`, and `page` materializes up to 200 such rows in one array (`ViewerStoreQuery.swift:209-226`, `278-300`). With legal near-20-MiB Events, a page can approach 4 GiB rather than holding bounded summaries plus one point-loaded detail. `begin` captures table maxima using separate autocommit statements, so writer commits can interleave the supposedly atomic snapshot (`ViewerStoreQuery.swift:239-251`). Continuation state contains only order keys, not the query fingerprint, upper bounds, direction, or lease token (`ViewerStoreQuery.swift:204-207`), and `page` accepts a separately supplied compiled query without proving it matches the query/cursor (`ViewerStoreQuery.swift:259-280`). Point detail lacks the required recording-session scope and can return an Event from another recording (`ViewerStoreQuery.swift:306-323`). Captured recording/device/disposition/gap/drop bounds are not applied to the returned row semantics.

Required remediation:

- Return bounded content-free summaries and load at most one scoped detail Event.
- Capture all upper IDs in one short read transaction and bind every upper ID, fingerprint, lease token/expiry, direction, and order key into an opaque validated cursor.
- Compile internally from the validated query and require recording ID for point detail.
- Add peak-memory tests with maximum-size Events, cross-recording detail tests, cursor substitution tests, equal-order pagination, mutation races, and generation-cancel coverage.

### NW-ISPD-006 — High — Export violates its memory, lease, cancellation, and schema guarantees

Each export page builds an array of as many as 200 fully encoded Event `Data` values, each accepted up to 20 MiB (`ViewerStoreExport.swift:139-180`), so memory can also approach 4 GiB instead of one Event plus a 64-KiB output buffer. The export lease is not tied to a recording (`ViewerStoreMaintenance.swift:86-99`), is never checked/touched after acquisition, and export continues after its 60-minute expiry while cleanup protection silently disappears. `cancel()` only interrupts a currently active SQLite statement (`ViewerStoreExport.swift:82`); cancellation during encoding, file writes, flush, rename, or between pages is lost. The API accepts up to 32 recording IDs (`ViewerStoreExport.swift:212-217`) rather than one complete recording or one validated query. Output contains only disclosure, devices, and Events (`ViewerStoreExport.swift:84-97`), omitting schema version, session, gaps, annotations, dispositions, and required metadata; most captured upper bounds are unused. This contradicts both the schema-versioned export and the documentation's frozen-snapshot claim.

Required remediation:

- Stream one Event directly from a short read step to bounded output chunks; never collect a page of full payloads.
- Bind the single export lease to its recording, validate it before/after every page and file phase, and use a persistent cancellation generation checked during query, encoding, writes, flush, pre-rename, and directory synchronization.
- Implement exactly one complete recording or one validated frozen query, including the documented schema/session/devices/Events/gaps/annotations and frozen version/disposition semantics.
- Add many-device/million-Event and maximum-payload memory/WAL tests, lease-expiry and cleanup races, cancellation at every phase, exact forbidden-field scans, and atomic replacement failure tests.

### NW-ISPD-007 — Medium — Database open and startup probes do not fully enforce the hardened SQLite contract

The store performs `lstat` checks but opens SQLite without `SQLITE_OPEN_NOFOLLOW` (`ViewerSQLite.swift:155-165`, `369-386`), leaving a check/open race that the static symlink test cannot exercise. There is no directory-descriptor-relative open strategy. Startup executes `PRAGMA journal_mode=WAL` but never verifies the returned mode, and the schema probe verifies foreign keys, secure delete, and temp storage but not WAL, synchronous mode, JSON1, FTS5 behavior, or read-connection invariants (`ViewerSQLite.swift:249-281`; `ViewerStoreSchema.swift:28-47`). Connections close in `deinit` outside their owning queues (`ViewerSQLite.swift:175-177`) rather than through explicit ordered shutdown.

Required remediation:

- Use `SQLITE_OPEN_NOFOLLOW` and a race-resistant parent/path policy, then revalidate owner/mode/type after open and while WAL/SHM are active.
- Probe the returned WAL/synchronous settings and execute fixed JSON1/FTS5 functional probes on the actual system library before accepting writes.
- Add explicit executor-owned statement/connection close and cancellation teardown.
- Extend tests to active WAL/SHM permissions, symlink swap races, unexpected regular-file replacements, feature/config failure, and exact resource release.

### NW-ISPD-008 — Medium — Query compilation is parameterized but its semantic and SQL trust boundaries remain incomplete

Most values are correctly bound and literal FTS quoting avoids direct user SQL injection. However, `ViewerCompiledQuery` carries raw `predicateSQL`, and the query service trusts a separately supplied compiled object (`ViewerStoreQuery.swift:45-49`, `259-280`) instead of owning compilation or verifying the fingerprint. NFC validation computes a normalized local copy but then binds and fingerprints the original strings (`ViewerStoreQuery.swift:57-78`, `176-191`). Global `.any` permits OR across dimensions, contrary to dimension-AND/value-OR semantics; App/Bundle, gap/drop presence, JSON existence/string-at-path containment, and per-predicate scalar OR lists are absent. `.contentContains` scans raw canonical JSON text rather than a validated string at a closed JSON path (`ViewerStoreQuery.swift:66-69`). The plan gate checks only one exact `USE TEMP B-TREE FOR ORDER BY` phrase and does not require the approved covering index (`ViewerStoreQuery.swift:356-367`).

Required remediation:

- Keep SQL fragments private to the compiler and compile/verify inside the query/export service.
- Bind the normalized value actually used for fingerprinting and implement the exact dimensional/JSON semantics.
- Treat any unsupported or unexpected `EXPLAIN QUERY PLAN` shape as a closed refine-query result and assert the covering timeline index.
- Add complete truth-table/pairwise and mutation tests for SQL/FTS operators, `%`, `_`, escapes, NUL/control, Unicode normalization, path bounds/types, and plan changes.

### NW-ISPD-009 — Medium — Lifecycle/disposition persistence is mutable and incomplete, undermining frozen history and safe reflection claims

Although the schema includes version tables, close and orphan reconciliation mutate `Recordings` and `DeviceSessions` base rows (`ViewerEventStore.swift:219-239`; `ViewerStoreCoordinator.swift:259-311`), while export reads those mutable bases and ignores captured version bounds. The integration emits no later expiry, overflow-displaced, session-ended, changed-policy, or changed-drop journal callbacks. The received initializer instead labels the Event `consumerAccepted` immediately (`ViewerEventStore.swift:37-50`) rather than persisting `buffered` and applying the later sequence-keyed terminal winner. `ViewerPreparedEventObservation` also stores the full envelope and canonical content in a normally reflectable internal value (`ViewerEventStore.swift:27-67`), with no redacted reflection contract or test. Frozen history can therefore change beneath a query/export, disposition history is incomplete, and accidental reflection/interpolation can expose Event data.

Required remediation:

- Keep base recording/device rows immutable and append all lifecycle/metadata changes to version tables selected by frozen upper bounds.
- Wire sequence-keyed idempotent terminal transitions plus policy/drop changes without blocking protocol owners.
- Make sensitive internal observation/query/detail models explicitly nonreflecting/redacted for diagnostic surfaces and add `String(describing:)`, `String(reflecting:)`, error, interpolation, log, and accessibility scans.

### NW-ISPD-010 — Medium — Documentation, privacy, and evidence claim completion that the tests do not establish

The operator guide states that observations are precomputed/nonblocking and gaps coalesce (`Documentation/Viewer-Local-Store.md:27-29`), that tombstoning targets 85% and impossible heads allow later progress (`:31-37`), that search normalizes/freeze-bounds history (`:41-45`), and that export is bounded/cancellable/frozen (`:47-53`); the implementation findings above contradict each claim. Production now calls `volumeAvailableCapacityKey` (`ViewerStoreMaintenance.swift:430-433`), but no saved privacy reassessment or built-manifest inspection explains whether the unchanged manifest (`Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy:5-15`) remains correct for the final macOS API use. Every implementation/test/evidence task from 2.1 onward remains unchecked (`openspec/changes/viewer-local-store-search/tasks.md:8-48`), and the 12 store tests cover only a narrow happy path (`ViewerStoreTests.swift:17-329`), with no failure injection, cancellation races, active sidecars, bounds/stress, privacy, reflection, or packaging evidence.

Required remediation:

- Correct documentation only after the implementation meets each guarantee; add a limitations/recovery statement for any deliberately deferred behavior.
- Record the exact volume-capacity API privacy decision, inspect the source and packaged privacy manifest, and preserve the existing UserDefaults/Device-ID declarations unless authoritative current policy requires a scoped change.
- Add the task-required deterministic, integration, adversarial, stress, packaging, and documentation tests and save exact current-tree evidence before checking tasks.
- Run the intended signed Viewer gate. The unsigned review run cannot satisfy entitlement assertions and is not completion evidence.

## Positive Controls Confirmed

- SQLite remains Viewer-only and uses the system library; no Core/SDK/root-package runtime dependency was introduced.
- Errors are closed enums without associated raw SQLite/path values, and SQLite error messages are freed rather than surfaced.
- Most SQL values use prepared bindings; validated numeric ID lists are the only current value interpolation in export/reclaim queries.
- Defensive mode, untrusted schema, foreign keys, memory-only temporaries, secure delete, full synchronization, bounded busy timeouts, progress handlers, and three separate serial connection owners are present as useful foundations.
- The Application Support directory and known main/sidecar files are chmod-restricted, static symlinks are rejected, and export temporary creation uses `O_EXCL | O_NOFOLLOW` with mode `0600`.
- Export disclosure accurately warns that output is unencrypted, pseudonymized rather than redacted, outside Viewer retention, and potentially synchronized or backed up.
- Recording name/note/annotation scalar, UTF-8, and control-character validation matches the approved numeric limits.

## Validation

### Required artifact gates

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
```

Result: passed, exit 0 — `Change 'viewer-local-store-search' is valid`.

```text
git diff --check
```

Result: passed, exit 0, no output.

### Viewer tests

The first default universal test attempt failed during the x86_64 Viewer compile because package module dependencies could not be resolved for that architecture.

An arm64 active-architecture diagnostic run compiled the current snapshot and executed 90 tests:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-store-security-review-current \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

Result: exit 65. All 12 `ViewerStoreTests` passed, but the full suite failed two assertions in `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement` because the diagnostic build disabled code signing; one stable-signer test was skipped. This run is useful compilation/unit evidence but is not the required signed packaging gate.

## Unresolved Count

**10 actionable findings remain unresolved: 6 high and 4 medium. Approval is withheld.**
