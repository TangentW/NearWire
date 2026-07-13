# Implementation Review Round 6 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined AGENTS.md; the complete active `viewer-local-store-search` proposal, design, capability specifications, and task plan; the complete current production, test, and operator-documentation change; all Round 5 implementation-review reports; `implementation-remediation-round5.md`; `implementation-validation-round6.md`; and `resource-filesystem-audit-round6.md`. It rechecked writer-serialized physical reserve, maintenance recovery below expensive plans, active Event carrier reflection/interpolation, bounded shutdown ownership, live filesystem restoration and cleanup, WAL logical-versus-allocated labeling, local SQLite/export encryption disclosure, export/path hardening, quota/allocated-footprint claims, privacy, packaging, and saved evidence accuracy.

Production, test, specification, task, and operator-documentation files were not modified. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to goal-level `release-hardening`; they are neither counted as findings nor represented as passing.

## Verdict

**Not approved. One actionable medium-severity finding remains.**

## Finding

### NW-ISPD6-001 — Medium — Active downlink queue owners and results still synthesize Event content, identifiers, and keep-latest keys

Round 5 remediation adds closed descriptions and mirrors to `EventEnvelope`, `EventEnvelopeContext`, `WireEventRecord`, `WireEventPayload`, `WireEventBatchPayload`, `WireFrame`, `WireFrameDecoder`, `WireMessage`, and `WireAdmittedMessage`. The new Core tests verify those exact values with a secret marker. The earlier received/downlink journal wrappers, prepared store observations, structural observations, and query/result models also remain closed.

The active Viewer downlink path still owns `EventDraft` values, which directly contain Event type, arbitrary `JSONValue` content, priority, TTL, and causality (`EventDraft.swift:3-8`). `EventDraft` has no custom description/debug description/mirror, and the Viewer retains it in `BoundedEventQueue<EventDraft>` (`ViewerMultiDeviceSession.swift:200-213,429-450`). The generic queue boundary is also open: `PendingEvent` exposes its `value`, Event ID, queue policy, and timing (`EventQueueConfiguration.swift:99-133`); `KeepLatestKey` and `EventQueuePolicy` expose the raw queue key (`EventQueueConfiguration.swift:7-39`); and `BoundedEventQueue` retains pending values, Event-ID indexes, and keep-latest-key indexes in synthesized reflection (`BoundedEventQueue.swift:178-232`). Dequeue/offer results and queue snapshots likewise synthesize pending values and Event IDs (`BoundedEventQueue.swift:24-90`). The uplink queue uses the same generic owners, so leaf-level redaction of `WireReceivedEvent` does not hide its surrounding queue identifiers and policy state.

Consequently, `String(reflecting:)`, debugger mirrors, failed assertion interpolation, or generic diagnostics on the draft, queue, pending/result, snapshot, or policy values can still reveal Event content, metadata identifiers, and queue keys. This directly conflicts with the capability requirement that every description, reflection helper, and interpolation exclude Event type/content/metadata plus queue keys and contents (`viewer-multidevice-flow-control/spec.md:7-11`). The Round 6 reflection tests cover only envelope/context and wire/frame/message carriers; no secret-marker regression exercises the active flow-control owners.

Required resolution:

- Add content-free reflection for `EventDraft` and every active generic flow-control owner/result that can retain a pending Event, Event ID, or keep-latest key, or enforce an equivalent nonreflecting ownership boundary.
- Give `KeepLatestKey`, `EventQueuePolicy`, and Viewer downlink policy closed redacted diagnostics so a queue key cannot appear independently of its Event.
- Extend the table-driven secret-marker test through `PendingEvent<EventDraft>`, populated `BoundedEventQueue<EventDraft>` and `BoundedEventQueue<WireReceivedEvent>`, dequeue/offer/clear/snapshot results, and both keep-latest policy representations. Test descriptions, debug descriptions, `String(reflecting:)`, `Mirror`, and interpolation.

## Round 5 Finding Disposition

- `NW-ISPD5-001`: resolved. Manual deletion and orphan reconciliation now compute/check their plans inside the serialized writer immediately before `BEGIN IMMEDIATE`; deterministic ordering and exact-plan regressions exist.
- `NW-ISPD5-002`: resolved for the named envelope, wire, frame, decoder, message, and admitted-message carriers. The remaining queue/draft ownership gap is captured separately by `NW-ISPD6-001`.
- `NW-ISPD5-003`: resolved. Shutdown performs exactly one ingress flush, closes finite ownership after failure, and leaves repair to the next open. Failure, pre-existing failed-prefix, and capacity-failure regressions cover the contract.
- `NW-ISPD5-004`: resolved. The audit records exact commands and metadata, restores the prior Application Support store, deletes the audit-created store and marker, and leaves no named residue. WAL values are correctly distinguished as logical versus allocated, and operator documentation now states that neither local SQLite nor JSON exports receive NearWire application-layer at-rest encryption.

## Rechecked Boundaries Without New Findings

- Maintenance can use one floor-only checkpoint or incremental-vacuum action when an expensive selection/reclaim plan is blocked, without mutating the blocked Event or tombstone, and remains within the eight-turn bound.
- The incremental-vacuum evidence accurately reports SQLite page/freelist progress without claiming immediate APFS logical or allocated-size shrinkage.
- Export retains the original temporary and parent descriptors, validates identities, commits with descriptor-relative `renameat`, preserves the prior destination on reported pre-commit failure, and discloses unencrypted, pseudonymous-but-not-redacted output outside Viewer retention.
- SQLite/FTS/JSON query values remain bounded and parameterized. Store paths remain owner-only and nonsymlink-validated; secure delete remains documented as defense in depth rather than guaranteed erasure.
- Logical quota and allocated main/WAL/SHM footprint remain distinct in production status and documentation.
- Root SwiftPM/CocoaPods boundaries, system SQLite linkage, and built privacy-manifest identity have current saved evidence. The macOS Required Reason API conclusion remains unchanged.

## Validation Basis

This review used the exact current-tree results saved in `implementation-validation-round6.md`: 133 unsigned Viewer tests with one explicit live-audit skip and zero failures, 533 root Swift package tests with seven documented skips and zero failures, and the separately passed opt-in live audit recorded in `resource-filesystem-audit-round6.md`. It did not duplicate unchanged passing suites. Source inspection identified the active queue/draft reflection paths absent from the saved secret-marker matrices.

## Unresolved Count

**One actionable finding remains unresolved: zero high and one medium. Approval is withheld.**
