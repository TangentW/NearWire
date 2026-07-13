# Security, Performance, Privacy, and Documentation Review

Scope: active OpenSpec change `viewer-event-explorer-control`. Signing and embedded-entitlement
verification was intentionally excluded per the approved deferral.

## Findings

### SPD-001 — P1: Protocol callback synchronously re-encodes and traverses Event content

Locations:

- `Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:710-780`
- `Viewer/NearWireViewer/Session/ViewerMultiDeviceSessionManager.swift:282-299`
- `Viewer/NearWireViewer/Session/ViewerCommittedEventObservation.swift:100-131`
- `Core/Sources/NearWireCore/Event/JSONValue.swift:97-150`
- `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:2922-3042`

`receiveSessionFrame` synchronously reaches `admitIncoming`, which calls `uplinkJournal` before
returning. The manager's journal closure constructs `ViewerCommittedEventObservation`, whose
initializer calls `envelope.content.deterministicData()`. That operation recursively traverses the
entire JSON value and allocates a new `Data`.

This contradicts the normative requirement that protocol-callback admission perform no JSON encoding
or content traversal. A maximum legal Event can contain roughly 16 MiB of content, making this an
attacker-controlled callback latency and transient-memory spike. The 100,000-offer test does not cover
this path: it constructs one observation before timing and repeatedly calls only `window.offer`, so its
claimed zero callback-side encoding/traversal evidence is incomplete.

Remediation:

- Carry canonical content bytes produced during existing wire validation/decoding into
  `WireReceivedEvent`, or prepare them once outside the latency-sensitive callback.
- Make `ViewerCommittedEventObservation` consume that immutable precomputed representation instead of
  invoking `deterministicData()`.
- Add end-to-end structural instrumentation around `receiveSessionFrame`, asserting zero new content
  encoding, traversal, or deep copy during journal/live admission.
- Correct the aggregate evidence until that full path is covered.

### SPD-002 — P1: Session metadata accumulation is unbounded under connection churn

Locations:

- `Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift:359-381`
- `Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift:518-585`
- `Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift:868-908`
- `Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift:941-965`
- `Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift:1007-1031`

`pendingSessionUpdates` accepts every new connection UUID without applying `maximumSessions`, unlike
the explicitly bounded `pendingDropCounts`. If the projection queue is blocked, repeated
connect/disconnect cycles can grow this dictionary and its eventual drain work without bound.

The projected `sessions` dictionary has a related lifetime issue: ended sessions are never reclaimed.
After 16 distinct historical connections, subsequent active sessions cannot acquire metadata even
when fewer than 16 sessions are currently connected. This turns the active-session limit into a
lifetime-connection limit.

Impact includes reconnect-driven memory/CPU denial of service and permanently degraded metadata after
routine long-running connection churn.

Remediation:

- Bound pending session IDs using an explicit active-plus-terminal retention policy.
- Reclaim ended session state once no retained live Event references it.
- Coalesce or deterministically evict terminal updates and record diagnostic loss with saturating
  counters.
- Add blocked-projection tests with hundreds or thousands of unique start/end UUIDs, asserting exact
  memory/cardinality bounds and continued admission of fresh active sessions.

### SPD-003 — P1: “Replaceable” preparation services retain an unbounded queue of content-bearing requests

Locations:

- `Viewer/NearWireViewer/Application/ViewerRendererRegistry.swift:544-600`
- `Viewer/NearWireViewer/Application/ViewerComposerPreparation.swift:382-438`
- `Viewer/NearWireViewer/Application/ViewerEventExplorerController.swift:1651-1691`
- `Viewer/NearWireViewer/Application/ViewerControlComposerController.swift:210-234`
- `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:4977-5034`

Both preparation services enqueue a new closure for every submission. Each closure captures its
complete request, including selected canonical Event content or composer input. Updating `activeToken`
causes obsolete work to return cancellation only when that closure eventually starts; it does not
remove or release queued content.

The rapid-selection test explicitly blocks the serial queue, submits 64 requests, and expects all 64
closures to complete. With legal maximum-size Event buffers, the same behavior can retain
approximately 1 GiB for 64 rapid selections, plus work-tracker entries. Cleanup must wait for every
obsolete closure, conflicting with the replaceable-generation and bounded-content ownership
requirements.

Remediation:

- Implement one executing request plus one latest-only pending slot.
- On replacement, immediately release the previous pending request's content.
- Track the bounded worker lifetime rather than every submission.
- Apply the same mechanism to renderer and composer preparation.
- Add blocked-worker stress tests asserting at most one running and one pending content buffer,
  bounded retained bytes, and prompt cleanup independent of submission count.

## Positive observations

- SQLite query values and JSON paths are parameterized, with VM-step and wall-time budgets.
- Export uses owner-only temporary files, no-follow/open validation, short paged reads, cancellation,
  and atomic replacement.
- Received Event controls disable editing, selection, clipboard commands, drag, and sharing;
  operator-input controls retain normal bounded editing behavior.
- Structured-content escaping covers control and bidirectional characters, with bounded accessibility
  output.
- The privacy manifest accounts for UserDefaults and device identity without tracking.
- Viewer sandbox and network-server entitlements are appropriately narrow for the advertised local
  service.

**Unresolved findings: 3**
