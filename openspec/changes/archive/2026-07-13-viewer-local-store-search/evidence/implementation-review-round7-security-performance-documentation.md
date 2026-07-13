# Implementation Review Round 7 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined AGENTS.md; the complete active `viewer-local-store-search` proposal, design, capability specifications, and tasks; the full current production, test, documentation, and evidence change; all Round 6 implementation-review reports; `implementation-remediation-round6.md`; `implementation-validation-round7.md`; `resource-filesystem-audit-round6.md`; and the relevant prior remediation/resource evidence. It retraced the Round 6 queue-reflection finding through active Viewer ownership and then rechecked sensitive interpolation, secure transport/event ownership, SQLite write gates and physical reserve, export/file atomicity, resource and quota/WAL claims, unencrypted local/export disclosure, privacy, packaging, and evidence accuracy.

Production, test, specification, task, and operator-documentation files were not modified. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to goal-level `release-hardening`; they are neither findings nor passing results in this report.

## Verdict

**Not approved. Two actionable medium-severity findings remain.**

## Findings

### NW-ISPD7-001 — Medium — Queue leaves are redacted, but active handoff and secure-transport owners still reflect identifiers, raw bytes, and connection state

Round 6's reported queue boundary is materially fixed. `EventDraft`, keep-latest keys/policies, `PendingEvent`, `BoundedEventQueue`, queue snapshots/results, `EventBatch`, `EventBatchAttempt`, and Viewer downlink policy now provide closed descriptions and mirrors. The generic queue regression covers populated pending/queue/result/batch shapes with a secret marker.

The remediation statement that the test drives populated `EventDraft` and `WireReceivedEvent` queues is inaccurate: `testActiveQueueOwnersAndResultsHaveContentFreeReflection` instantiates `PendingEvent<String>` and `BoundedEventQueue<String>` only (`BoundedEventQueueTests.swift:7-84`). Generic wrapper redaction is source-level independent of `Value`, and `EventDraft` itself is separately redacted in production, so this narrow test does not reopen the exact Round 6 defect. It does, however, leave the claimed active-type regression absent.

More importantly, active owners immediately outside those queues remain open:

- `ViewerUplinkHandoff.Item` stores the queue Event ID and `WireReceivedEvent`; `ViewerUplinkPayload` retains that item; and `ViewerUplinkHandoff` retains the payload while an operation is in flight (`ViewerMultiDeviceSession.swift:1251-1339`). None has closed reflection, so generic reflection can expose the queue identifier despite the redacted received-Event leaf.
- `SecureByteChannelEvent.received(Data)` carries complete incoming network bytes and has synthesized enum reflection (`SecureByteChannel.swift:8-13`). Viewer admission consumes this exact event (`ViewerAdmission.swift:358-363,508-525`).
- `SecureSendMailbox.Item` and its mailbox retain outgoing `Data` (`SecureByteChannel.swift:507-519`), while `SecureByteChannel` owns that mailbox and a connection driver without a closed mirror (`SecureByteChannel.swift:78-107`). Reflection can therefore traverse retained wire payloads or driver state.
- `SecureViewerListenerEvent.incoming` retains `SecureViewerIncomingConnection`; that wrapper owns an `NWConnection` and admission gate (`SecureByteChannel.swift:762-769,1033-1048`). Both event and wrapper use synthesized reflection, allowing connection/endpoint implementation state to reach generic diagnostics.

These values are active Viewer boundaries, not hypothetical unused models. Their default `String(reflecting:)`, debugger mirrors, assertion interpolation, or generic diagnostics conflict with the capability requirement excluding Event metadata, queue keys/contents, endpoints, certificate/transport state, and raw bytes from every such surface (`viewer-multidevice-flow-control/spec.md:7-11`). No current secret-marker test covers handoff IDs, raw secure-channel events, pending send bytes, or incoming connection wrappers.

Required resolution:

- Add closed content-free reflection to the uplink handoff item/payload/owner boundary, exposing at most fixed count/in-flight state and never queue IDs or Event values.
- Redact `SecureByteChannelEvent`, `SecureViewerListenerEvent`, and `SecureViewerIncomingConnection`; expose only closed event/state categories and bounded byte counts where operationally necessary.
- Ensure the channel/send-mailbox ownership chain cannot reflect retained `Data`, connection endpoints, certificate state, or handler/driver internals.
- Extend the secret-marker matrix with actual `EventDraft` and `WireReceivedEvent` queues plus uplink handoff, received raw bytes, queued send bytes, and listener-event representations. Exercise descriptions, debug descriptions, `String(reflecting:)`, `Mirror`, and interpolation.

### NW-ISPD7-002 — Medium — Completion evidence retains an unexplained current-tree timing failure

`implementation-validation-round7.md` records a clean preserved-log SwiftPM run of 534 tests, but it also states that an earlier complete current-tree run reported one timing-sensitive failure and that the failing test line was lost to output truncation. The subsequent clean run is valid evidence for that invocation; it does not identify the failed test, establish whether the failure was environmental or a product race, or demonstrate repeatability of the affected boundary.

This change has already required repeated remediation for timing-sensitive runtime/shutdown ownership. Classifying an unknown failure as “timing-sensitive” without the failing test, result bundle, root cause, or repeated targeted evidence is not sufficient to close it. AGENTS.md explicitly prohibits claiming completion from evidence narrower than the requirement, and a single successful rerun cannot erase a known unexplained complete-suite failure.

Required resolution:

- Recover the failed test identity from the earlier result bundle/log if available; otherwise rerun the complete suite with durable untruncated logging until the failure is reproduced or a statistically meaningful clean sequence is recorded.
- If reproduced, root-cause and fix it, then add deterministic focused coverage and rerun the complete package/Viewer gates as applicable.
- Update validation evidence to distinguish the original failed invocation, investigation result, repeat commands, and final unchanged-tree result rather than leaving the failure unresolved behind one green rerun.

## Round 6 Finding Disposition

- `NW-ISPD6-001`: resolved for `EventDraft`, generic queue owners/results/batches, keep-latest policies, and Viewer downlink policy. The adjacent active handoff and secure-transport reflection gap is a fresh issue recorded as `NW-ISPD7-001`.
- Round 6 architecture findings for maintenance-to-ingress gating and writer-serialized checkpoint admission are resolved by the shared state relay and same-writer reserve decision.
- Round 6 correctness findings for SQLite lock origin/manual-delete failure classification and cumulative drop journaling are resolved with distinct `sqliteBusy`, authoritative mutation reporting, cumulative per-reason samples, monotonic store validation, and focused regressions.

## Rechecked Boundaries Without New Findings

- Manual delete, metadata/annotation writes, Event ingress, orphan reconciliation, maintenance work, and checkpoint admission use serialized reserve/mutation boundaries. Maintenance failure now closes ingress until an approved explicit recovery action.
- Shutdown performs one finite flush and relies on next-open orphan reconciliation after failure; it has no automatic retry loop.
- Export retains original temporary and parent descriptors, validates identities, commits through descriptor-relative `renameat`, preserves the prior destination on reported pre-commit failure, and documents unencrypted pseudonymous-but-not-redacted output outside Viewer retention.
- SQLite/FTS/JSON inputs remain bounded and parameterized. Logical quota remains distinct from allocated main/WAL/SHM footprint, and APFS evidence does not promise immediate physical shrinkage.
- The live filesystem audit records restoration and residue cleanup. Store files remain owner-only and nonsymlink-validated; secure delete remains defense in depth rather than guaranteed erasure.
- Operator documentation explicitly states that local SQLite and JSON exports receive no NearWire application-layer at-rest encryption and that FileVault is outside NearWire's guarantee.
- Root manifest boundaries, Swift 5/platform declarations, CocoaPods validation, system SQLite linkage, and built privacy-manifest identity have current saved evidence. The macOS Required Reason API conclusion remains unchanged.

## Validation Basis

This review used the saved Round 7 focused and complete results: 140 unsigned Viewer tests with one explicit live-audit skip and zero failures in the final invocation, plus 534 Swift package tests with zero failures in the preserved-log rerun. It did not count the two excluded configured-signing tests. Source-level inspection found the active handoff/secure-transport reflection paths, and the validation document itself supplies the evidence basis for the unresolved earlier SwiftPM failure.

## Unresolved Count

**Two actionable findings remain unresolved: zero high and two medium. Approval is withheld.**
