# Pre-Implementation Correctness and Testing Review — Round 6

## Verdict

**Approved for implementation.** The current common artifact snapshot defines a durable duplicate
projection that is exactly representable by the existing Events storage, closes endpoint and epoch
validation before either journal path, and gives task 6.3 a complete deterministic equality,
conflict, invariant, and authority-state test matrix. The round-5 migration-pool and clipboard
corrections remain intact.

| Severity | Unresolved count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| **Total actionable** | **0** |

This is approval of the pre-implementation artifacts only. Every implementation task, stated test,
evidence capture, post-implementation review, spec-to-evidence audit, and archive gate remains
required.

## Scope and Method

This review reread the current proposal, design, task plan, all three delta specifications, and
`pre-review-remediation-round5.md`. Earlier review reports were treated as historical finding
indexes rather than approval of the changed snapshot. The current normative artifacts were the
conformance authority.

The changed duplicate language was checked against:

- the complete `EventEnvelope` value;
- the current `Events` and sequence-zero `EventDispositionVersions` schema;
- the existing Event insert and collision seams;
- the Viewer uplink and downlink commit order and wire sequence validator; and
- every duplicate authority and loss-of-authority state named by task 6.3.

The migration-pool and clipboard boundaries changed in round 5 were then rechecked for regression.
No production or test source and no artifact other than this report was modified.

## Durable Semantic Projection

### The projection matches current durable storage exactly

The revised comparator no longer claims to compare values that the durable store intentionally
does not retain. Its identity and compared fields map to current storage as follows:

| Comparator component | Durable representation | Review result |
| --- | --- | --- |
| Runtime and connection | Active runtime/connection maps to the exact recording and device-session rows used by the store key | Representable and stable for the journal operation |
| Direction and wire sequence | `Events.direction` and `Events.wireSequence`, inside the unique `(recordingID, deviceSessionID, direction, wireSequence)` key | Exact identity |
| Event ID and type | `Events.eventUUID` and `Events.eventType` | Exact field comparison |
| Event content | Canonical bytes in `Events.contentJSON` | Exact byte comparison; no hash-only decision |
| App-created wall time | `Events.createdWallMs` | Same one-time `Int64((secondsSince1970 * 1,000).rounded())` normalization used by insertion |
| App monotonic time | `Events.originMonotonicNs` | Exact integer comparison |
| Priority, TTL, and schema | `Events.priority`, `Events.ttlMs`, and `Events.schemaVersion` | Exact field comparison |
| Causality | `Events.correlationEventUUID` and `Events.replyToEventUUID` | Exact optional-field comparison |
| Initial disposition | Sequence-zero `EventDispositionVersions.disposition` | Exact semantic comparison |

This covers every durably stored Event semantic value. It also correctly excludes store-local values
that do not change Event meaning: the later observation's Viewer wall/monotonic receive times,
deterministic byte accounting, quota accounting, and frozen presentation/session aliases. Equality
preserves the first row's receive and accounting values. A later change to any compared field or to
the initial disposition is a typed journal conflict, not generic store corruption.

Source, target, and session epoch are `EventEnvelope` semantics but are not columns in `Events`.
Their exclusion is correct only because they are exact-session pre-journal invariants; that premise
is satisfied by both transport directions as verified below. No schema column, content copy, or
privacy-sensitive identity/epoch retention is needed.

### Nearest-millisecond normalization is deterministic

The design specifies the exact conversion expression rather than an implementation-selected
rounding policy:

`Int64((secondsSince1970 * 1,000).rounded())`

That is the same conversion already used for `Events.createdWallMs` insertion. Consequently, the
live and durable comparators have one oracle: two App-created values are equal exactly when this
conversion produces the same integer; a different integer conflicts. Sub-millisecond source values
are supported without pretending that the current database retains greater precision. Task 6.3
requires both equivalence classes and the crossing case, so an implementation that truncates,
compares the original `Date`, samples a new time, or uses a different rounding rule cannot pass.

The excluded-field rule is equally deterministic: metadata, accounting, and later Viewer receive
time differences remain equal and preserve the first values; persisted-projection and initial-
disposition differences conflict. The direct field/byte requirement prevents hash collision or
hash-instability ambiguity.

## Pre-Journal Session Invariants

### App-to-Viewer

Before creating any journal commit, `ViewerMultiDeviceSession` requires the incoming source to be
the exact negotiated App installation endpoint and the target to be the exact negotiated Viewer
installation endpoint. `WireSequenceValidator` then requires the exact session epoch, direction,
and next directional sequence. Validation is performed against planned state, and only after the
whole admitted batch succeeds does the session publish the planned state and invoke the uplink
journal callbacks.

Therefore a source, target, direction, epoch, or sequence mismatch cannot reach live ingress or the
store writer through the uplink path.

### Viewer-to-App

The Viewer constructs each downlink envelope from the exact negotiated Viewer source, exact
negotiated App target, active session epoch, Viewer-to-App direction, and sequence allocated by the
session-owned counter. It invokes the downlink journal only after secure-mailbox admission commits
and the planned queue/counter state is installed.

Therefore no caller-provided endpoint or epoch can bypass the session boundary and enter the
downlink journal comparator. A reconnect receives a distinct connection/session identity, so
sequence reuse across connections does not alias an earlier journal key.

These invariants are sufficient for excluding source, target, and session epoch from durable
duplicate comparison. Task 6.3 also requires explicit negative evidence: mismatches must be rejected
before journal commit, so tests must observe zero durable rows, live candidates/markers, and journal
callbacks for those cases.

## Task 6.3 Coverage Matrix

Task 6.3 now covers all required duplicate decisions across the complete bounded-authority
lifecycle:

| State | Equal projection | Compared-field conflict | Endpoint/epoch mismatch |
| --- | --- | --- | --- |
| Pending ingress | Idempotent; first values retained | First live value retained; one bounded presentation conflict; no store fan-out | Rejected before journal admission |
| Projection drain/retained window | Idempotent; first values retained | First live value retained; bounded conflict marker | Rejected before journal admission |
| Evicted live key | Live authority has deliberately forgotten the key; overflow marker discloses horizon loss | A later candidate may become the new transient first | Rejected before journal admission |
| `untracked` ingress | Writer remains the only durable authority | Writer decides against any existing durable row | Rejected before journal admission |
| Existing durable row | No-op; later transient candidate reconciles without rewriting the row | Immutable row preserved; typed content-free `journalConflict` | Rejected before journal admission |
| Storage unavailable/recovery | Bounded live authority behaves as above; durable decision resumes only where a row exists | No global first-wins claim after both authorities forget; recovery does not invent history | Rejected before journal admission |
| Shutdown/runtime replacement | Joined work cannot publish late equality/conflict state; bounded content is cleared | No stale marker, row mutation, or callback after cleanup | Rejected before journal admission |

Within every state where a comparator can run, task 6.3 requires:

- equality for metadata-only, deterministic-accounting-only, later-receive-time-only, and
  sub-millisecond-created-time differences that normalize to the same millisecond;
- preservation of the first receive/accounting values for those equal cases;
- conflict for every persisted-projection field, initial disposition, and created time that
  normalizes to a different millisecond;
- direct field/byte comparison rather than hash-only equality; and
- exact store availability/status, durable row count/content, live candidate/marker, callback, and
  drain-count outcomes.

The authority states, equality partitions, conflict partitions, and pre-comparator invariants are
therefore all observable. The task does not leave a duplicate outcome to implementation choice.

## Round-5 Regression Checks

### Migration-only connection remains isolated from the normal pool

The design, local-store requirement, and tasks still require the migration writer to be the sole
startup connection, use the system default VFS/process-private temporary directory, and leave all
normal readers closed. Commit or rollback is followed by closing that writer and joining to zero
sorter descriptors. Success then opens and probes a fresh normal writer with
`temp_store=MEMORY` and an explicit 8-MiB cache before opening two equally fresh readers and
publishing availability. Post-open failure closes the fresh connections.

The independent database/temp-volume preflight, checked capacity expression, 256-MiB progress
floor, rollback, cancellation, termination, retry, plan/index probes, sorter-content restriction,
128-MiB fixture heap-growth gate, and 250-ms injected cancellation acknowledgement remain present
in tasks 2.1 and 6.1. No migration-only FILE-temp or 32-MiB setting can enter the published pool.

### Clipboard editing and disclosed file export remain separate

Operator-owned editable composer, filter, and metadata controls still permit standard user-invoked
copy/cut/paste, with pasted replacements checked against caps before model storage. Received or
stored Event inspector controls still expose no copy, cut, drag, share, or clipboard-export command,
and NearWire performs no background pasteboard read, monitoring, restoration, or clipboard history.

Tasks 5.5 and 6.4 retain actual macOS keyboard and contextual-command coverage. They also explicitly
preserve the separately disclosed JSON file-export workflow, so the inspector privacy restriction
does not accidentally remove the approved export feature.

## Other Correctness Regression Check

The prior correctness areas remain closed in the current snapshot: coordinator generations and
successor-safe cancellation; source-neutral current/history scopes; immutable catalog and gap
traversals; bounded causality; pause/resume/shutdown generation handling; terminal capability
classification; renderer/composer bounds; and exact cleanup/join requirements. The duplicate
projection correction changes none of those contracts.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict` exited 0 with
  `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` exited 0 with no output.
- `git status --short` showed only the active untracked OpenSpec change directory.
- No production or test source and no artifact other than this report was modified by this review.

## Conclusion

There are **zero unresolved correctness/testing findings** in the current pre-implementation
artifact snapshot. This snapshot is approved for the correctness/testing dimension of the required
fresh common-snapshot review. Implementation may begin only after the same snapshot receives the
other required zero-finding review approvals and the workflow gate is completed.
