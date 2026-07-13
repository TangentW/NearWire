# Implementation Review Round 8 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined `AGENTS.md`; the complete active `viewer-local-store-search` proposal, design, capability specifications, and tasks; the complete current production, test, documentation, and evidence change; all Round 7 implementation-review reports; `implementation-remediation-round7.md`; `implementation-validation-round8.md`; and the current resource/filesystem audit. It retraced both Round 7 security/performance/documentation findings and then rechecked the complete Viewer ownership graph for Event values, queue identifiers, raw transport bytes, peer identities, endpoints, callbacks, SQLite/store state, export/file handling, resource limits, privacy declarations, packaging claims, and documentation accuracy.

The latest tree was used, including removal of the unused `successfulReopen` recovery case. Production, test, specification, task, and operator-documentation files were not modified. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to goal-level `release-hardening`; they are neither findings nor passing results in this report.

## Verdict

**Not approved. One actionable medium-severity finding remains.**

## Finding

### NW-ISPD8-001 — Medium — Viewer admission/session/store roots reopen peer identities and raw Hello bytes through synthesized reflection

Round 7 remediation closes the reported queue, uplink-handoff, secure-channel, send-mailbox, listener, incoming-connection, admission-gate, store-ingress, and writer-state-relay boundaries. Those changes prevent generic diagnostics from traversing the sensitive values retained immediately by those owners. The ownership graph one layer above them is still synthesized, however, and directly contains sensitive values that do not pass through a redacted leaf:

- `ViewerAdmissionSessionContext` stores the internal connection UUID and complete App and Viewer `WireHello` values (`ViewerAdmission.swift:47-53`). `WireHello` has synthesized reflection and directly contains the installation identifier, display name, application identifier/version, and negotiation capabilities (`WireControlPayloads.swift:7-21`). Default struct reflection and interpolation therefore expose installation/correlation identity and peer text.
- `ViewerAdmissionConnectionCore` retains its queue UUID, connection UUID, encoded Viewer Hello `Data`, complete Viewer and App Hello values, channel, decoder, callbacks, session receiver, pause token, and waiters (`ViewerAdmission.swift:279-323`). `ViewerAdmissionHandle` retains that core (`ViewerAdmission.swift:237-277`), and `ViewerAdmissionManager.Attempt` plus the manager's attempt dictionary retain the core, connection/generation UUIDs, cleanup owner, summary, and deadline task (`ViewerAdmission.swift:969-1013`). These classes do not provide closed mirrors, so recursive `Mirror` inspection can bypass the newly redacted secure-transport wrappers and reach the raw Hello frame, identities, handlers, and transport/session ownership.
- The context remains active after admission. `ViewerDeviceSession` retains the handle, core, context, connection UUID, exact session epoch, queue-keyed journal dictionary, callbacks, and both Event queues (`ViewerMultiDeviceSession.swift:203-270`). `ViewerMultiDeviceSessionManager.Entry` retains each session and connection UUID (`ViewerMultiDeviceSessionManager.swift:5-43`). The new local-store path also retains complete contexts in `ViewerStoreCoordinator.nondurableConnections` (`ViewerStoreCoordinator.swift:107-165`) and `ViewerStoreRuntime.activeSessions` (`ViewerStoreCoordinator.swift:1223-1244`). None of these root owners has closed reflection.

This violates the modified Viewer capability requirement that every reflection helper, description, interpolation, and diagnostic surface derive only from a closed local code or bounded presentation model and exclude installation/correlation identifiers, session epochs, endpoints, peer text, raw bytes, queue keys/contents, and underlying implementation state (`viewer-multidevice-flow-control/spec.md:7-11`). The current secret-marker regressions stop at `SecureByteChannel`, `SecureViewerIncomingConnection`, listener events, Event queues, and `ViewerUplinkHandoff`; they do not exercise an admitted context, connection core, handle, attempt/manager, active device session, session manager, store coordinator, or store runtime.

Required resolution:

- Give `WireHello` and `ViewerAdmissionSessionContext` closed content-free descriptions and mirrors, or replace them at every diagnostic boundary with an explicitly bounded safe presentation. No installation ID, connection ID, peer text, or negotiation payload may be reflected.
- Close reflection for the active admission ownership chain (`ViewerAdmissionConnectionCore`, handle, weak ingress/cleanup owners as applicable, manager/attempt) and expose at most closed lifecycle categories and bounded counts.
- Close reflection for the active post-admission roots (`ViewerDeviceSession`, `ViewerMultiDeviceSessionManager`, `ViewerStoreCoordinator`, and `ViewerStoreRuntime`) so their mirrors cannot recursively reach contexts, raw frames, queue keys, Event values, session epochs, database paths, handlers, or transport/store internals.
- Add secret-marker regressions that construct a real App Hello with distinctive installation/display/application values and raw encoded bytes, drive it through an admitted core/context/handle and active session/store ownership, and verify descriptions, debug descriptions, `String(reflecting:)`, interpolation, and recursive mirror traversal at every root.

## Round 7 Finding Disposition

- `NW-ISPD7-001`: resolved at every boundary it named. The Core regression now drives received bytes, a channel with pending send bytes, an incoming connection, and its listener event; the Viewer regression drives real `EventDraft` and `WireReceivedEvent` queues plus uplink item/payload/owner. The higher admission/session/store root gap is a fresh issue recorded as `NW-ISPD8-001`.
- `NW-ISPD7-002`: resolved. Durable logging identified two independent test-observation races. Each corrected focused test passed 100 independent processes, and the complete 535-test package passed 20 consecutive independent processes with retained per-run logs and no failed-test/error match.
- The Round 7 architecture/correctness findings are materially resolved by generation-bound writer authorization, typed recovery actions, recovery publication only after complete success, and cumulative drop validation before cleanup. The latest `ViewerStoreRecoveryAction` contains only explicit retry, settings change, unpin, and manual delete; successful reopen creates a fresh validated owner rather than a mutable recovery enum transition.

## Rechecked Boundaries Without Additional Findings

- One authoritative writer state/generation now gates automatic Event writes, direct materialization, maintenance failure, ingress scheduling, and finite recovery. Stale tickets are rejected again on the serial writer before the injected seam, planning, reserve admission, and transaction begin.
- Recovery is action-specific. Rename, annotation, pin, ordinary cleanup, capacity reduction, and longer retention cannot reopen ingress; explicit retry, improving settings changes, unpin, and confirmed deletion require successful bounded work first.
- Cumulative drop planning rejects lower samples before quota/cleanup, treats equal samples as no-ops, saturates at `Int64.max`, and records a bounded operation-local gap rather than changing global writer state.
- SQLite inputs remain bounded and parameterized. Writer/query/export connection ownership, progress budgets, logical quota versus main/WAL/SHM disclosure, and APFS physical-reclamation limits remain accurately documented.
- Export retains and validates original temporary/parent descriptors, commits with descriptor-relative rename, preserves the prior destination on reported pre-commit failure, and clearly discloses ordinary unencrypted pseudonymous JSON outside Viewer retention.
- The live filesystem audit remains applicable to the unchanged store paths and creation/cleanup implementation: owner-only main/WAL/SHM artifacts were observed, the prior store identity was restored, and no audit residue remained.
- Operator documentation accurately states that the local SQLite store and JSON export have no NearWire application-layer at-rest encryption and that FileVault is outside NearWire's guarantee. The privacy manifest and Required Reason API conclusion remain consistent with the implementation.
- Root packaging boundaries, Swift 5 language mode, iOS 16/macOS 13 declarations, no third-party Core/SDK runtime dependency, system SQLite linkage, CocoaPods validation, and built privacy-manifest identity have current saved evidence.

## Validation Basis

This review used the saved Round 8 results: strict OpenSpec validation; focused writer/recovery/drop/reflection regressions; 66 Viewer store tests with one explicit live-audit skip; 20 consecutive complete Swift package runs of 535 tests with zero failures after two identified and corrected test-observation races; and the final unsigned Viewer run of 146 total tests, 145 passed, one explicit live-audit skip, and zero failures. It did not count the two excluded configured-signing tests. The remaining finding is source- and ownership-graph-based and is not exercised by the current reflection matrix.

## Unresolved Count

**One actionable finding remains unresolved: zero high and one medium. Approval is withheld.**
