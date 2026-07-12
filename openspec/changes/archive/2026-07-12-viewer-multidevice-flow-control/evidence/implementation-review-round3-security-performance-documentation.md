# Implementation Review Round 3: Security, Performance, and Documentation

## Scope and Verdict

This independent review re-read `AGENTS.md`, the active proposal/design/spec/tasks, the Round 2 security/performance/documentation report, the current Core and Viewer diff, session/admission/preferences/manager/UI code, the updated focused tests and operator guide, and the saved implementation, privacy, and requirement-to-evidence reports. No production, test, specification, or task source was modified; this report is the only file added by this review.

Coverage was assessed proportionately for this internal Viewer change and the product owner's explicit direction to avoid over-engineering. The focused tests exercise the changed security and scheduling seams, while the saved package, Viewer, iOS, Core, TLS, distribution, and bootstrap suites provide broad regression evidence.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**

**Approved for the security, performance, and documentation dimension.**

## Round 2 Finding Disposition

| Round 2 finding | Round 3 disposition |
| --- | --- |
| `NW-MFC-IMPL-SPD-R2-001` blocked uplink handoff retained a batch after terminal | Resolved. Delivery transfers one Event at a time, not a batch. One static `OperationQueue` caps concurrent consumer execution at 16. Cancellation atomically detaches and clears a not-yet-started payload; after `take()`, only the current consumer-owned value can remain in a blocked synchronous callback. |
| `NW-MFC-IMPL-SPD-R2-002` oldest-wait telemetry and documented bounds were absent | Resolved. Both queue waits are computed from the queue clock, included in snapshots, cleared for recent rows, rendered in the detail view, and documented with the work/input/system limits and terminal categories. |
| `NW-MFC-IMPL-SPD-R2-003` validation/privacy evidence was incomplete and focused tests failed | Resolved. The focused suite, full Viewer regression, Swift package suite, repository bootstrap, formatting, structure/package gates, OpenSpec validation, requirement audit, and built privacy inspection now have saved successful evidence. |
| `NW-MFC-IMPL-SPD-R2-004` route and policy reflection exposed identifiers/rates | Resolved. Route, policy, and aggregate snapshot provide closed custom description/debug/reflection surfaces, with sentinel coverage for each directly exposed value. |

## Security and Performance Verification

### Bounded uplink consumer ownership

- `deliverUplink` dequeues and transfers at most one Event per consumer handoff. Queue/token state commits only after that one handoff accepts ownership (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:592-631`).
- The shared worker queue caps concurrent execution at the same 16-session product bound (`ViewerMultiDeviceSession.swift:1024-1031`). Each session owns at most one in-flight handoff.
- A payload wrapper owns the Event until exactly one `take()` or `clear()`. Cancellation removes the operation/payload references under the handoff lock, clears unstarted Event content, and cancels the operation. A callback that already took the Event owns only that current value; no residual batch exists (`ViewerMultiDeviceSession.swift:1033-1112`).
- The connection protocol executor never waits for consumer work. The blocked-consumer test proves that Control input and response continue while the sink is blocked (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:439-482`).
- Terminal paths cancel the handoff, clear both session queues, account connection-owned clears with saturating typed telemetry, and then continue exact core cleanup (`ViewerMultiDeviceSession.swift:849-875`).

This design puts a finite ceiling on NearWire-owned Event payloads even if a synchronous consumer never returns. The one currently executing value is explicitly transferred consumer ownership; queued or ended-session batches cannot accumulate.

### Input, queue, mailbox, and timer bounds

- Active input remains overflow-checked against the negotiated maximum frame plus two receive chunks and the 19 MiB hard ceiling. Decoder-retained bytes and callback `Data` share one charged budget.
- Per-session queues remain capped at 5,000 Events and 16 MiB each. Service work is split into finite 32-record slices and at most 128 scheduled business records before yielding. Receive turns retain the separate 64-frame, 512-record, and 32-system-message bounds.
- System traffic remains token-bounded at 64 messages per second with a burst of 128. Zero-rate business queues retain TTL service without a recurring batch poll.
- Business sends and the one in-flight drop summary preserve one Control slot and 64 KiB. Local overflow, expiry, coalescing, and connection-clear counters saturate independently; the wire summary retains the available V1 categories.
- Session and manager scheduling remain one-shot and replaceable. No recurring idle timer, per-row timer, or unbounded continuation owner was introduced.

### Persistence, identity, and diagnostic privacy

- Preference input is rejected above 2 MiB before JSON decoding. Stored state remains limited to the global requested policy, 256 Bundle policies, and 256 route nicknames with validated keys/values and deterministic eviction.
- Effective policy, Event drafts/content, encoded payloads, queue keys, queue contents, session epochs, recent session state, endpoints, and TLS material are absent from preference persistence, logs, analytics, clipboard, and export.
- Peer-declared installation and Bundle values remain explicitly unauthenticated presentation/correlation hints. Exact-route duplicate handling does not convert them into authorization, and downlink remains connection/epoch-bound.
- `ViewerLogicalRoute`, `ViewerRatePolicy`, and `ViewerSessionSnapshot` now expose only closed diagnostic strings/mirrors (`Viewer/NearWireViewer/Session/ViewerDevicePreferences.swift:19-47`; `Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:57-75`). Sentinel tests cover direct description, debug/reflection, identifiers, and rate values (`Viewer/NearWireViewerTests/ViewerFlowControlTests.swift:774-839`).
- No new logger, analytics SDK, database, clipboard/export path, third-party runtime dependency, nested manifest, entitlement, or tracking behavior was added.

## UI and Documentation Verification

- Live snapshots include uplink/downlink count, bytes, and oldest-wait values from the injected monotonic queue clock (`ViewerMultiDeviceSession.swift:878-915`). Recent rows clear effective rates, queue values, throughput, and oldest waits (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSessionManager.swift:449-489`).
- The detail view renders both oldest waits alongside count and bytes; empty queues use fixed safe text (`Viewer/NearWireViewer/UI/ViewerRootView.swift:233-292`).
- The English operator guide accurately documents the 16/64 ownership limits, 5,000-Event/16-MiB queues, 500 ms batching, Control reservation, 32/64/128/512 service and ingress limits, system rate/burst, 2 MiB default/19 MiB hard input bounds, typed drops, memory-only exclusions, privacy rationale, closed terminal categories, and one-Event/16-operation consumer boundary (`Documentation/Viewer-MultiDevice-Flow-Control.md:9-63`).
- The UI labels App identity as unauthenticated and keeps Event content/history/search/filter/export/control composition/performance charts outside this change.

## Validation and Packaging Evidence

Saved evidence under this change records:

- 20 focused Viewer flow-control tests passed, plus 50/50 repetitions of the formerly intermittent bidirectional test.
- The selected unsigned Viewer regression suite passed 74 tests with zero failures. The two signing-dependent checks are explicitly deferred by product decision to `release-hardening` rather than silently weakened.
- `swift test` passed 530 tests with zero failures.
- `./Scripts/verify-bootstrap.sh` passed all gates, including 531 iOS tests with zero failures, 206 Core tests with zero failures, real TLS active-session and public-connect integrations, SwiftPM, CocoaPods, and repository validation.
- Strict Swift formatting, `git diff --check`, and strict OpenSpec validation passed.
- The requirement-to-evidence audit maps every non-signing requirement to implementation and executable/inspection evidence.
- Built-app privacy inspection found UserDefaults reason `CA92.1`, linked Device ID for App functionality, tracking false, and no tracking domains (`evidence/implementation-validation.md`; `evidence/privacy-manifest-inspection.md`; `evidence/requirement-to-evidence-audit.md`).

This reviewer independently reran the current 20-test Viewer flow-control suite with a clean derived-data path; it passed with exit 0. The current built privacy manifest matched the saved declaration. Strict OpenSpec validation and `git diff --check` also passed.

## Approval

No unresolved security, privacy, resource-bound, performance-isolation, diagnostic, documentation, UI-accuracy, or packaging-evidence issue remains in this review dimension. The change may proceed to the remaining independent review/audit/archive gates.
