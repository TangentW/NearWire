# Implementation Review Round 9 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined `AGENTS.md`; the complete active `viewer-local-store-search` proposal, design, capability specifications, and task plan; the complete current production, test, packaging, operator-documentation, and evidence tree; all three Round 8 implementation-review reports; `implementation-remediation-round8.md`; `implementation-validation-round9.md`; and the current live resource/filesystem audit. It retraced every Round 8 finding and then re-audited synthesized and custom reflection from `WireHello` through admission, active session, store, SQLite, query, export, status, and callback roots; secret-marker coverage; queue/task/work bounds; writer and recovery interleavings; SQLite/path/export hardening; resource claims; privacy declarations; packaging evidence; and documentation accuracy.

Production, test, specification, task, and operator-documentation files were not modified. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to goal-level `release-hardening`; they are neither findings nor passing results in this report.

## Verdict

**Not approved. One actionable medium-severity finding remains.**

## Finding

### NW-ISPD9-001 — Medium — The latest-only store callback value still reflects internal recording and Event row identities

Round 8 remediation closes the complete sensitive owner chain it named: `WireHello`, admission context/core/handle/manager and cleanup owners, active device/session-manager owners, store coordinator/runtime, and the operational SQLite/query/export/maintenance/preference/status/lease/service roots all provide closed descriptions and mirrors. The new tests drive distinctive peer markers through real Hello, admission, active-session, coordinator, and runtime ownership.

The value actually delivered by the latest-only status/change callback remains open. `ViewerStoreChangeSnapshot` uses synthesized diagnostics and stores `changedRecordingIDs`, `eventUpperRowID`, and the safe status (`ViewerEventStore.swift:221-225`). `ViewerStoreStatusSignal` retains and merges that snapshot and passes it to an arbitrary handler (`ViewerEventStore.swift:227-307`). The signal owner now has a closed mirror, but the callback value does not. Default `String(describing:)`, `String(reflecting:)`, interpolation, and `Mirror` therefore expose the exact internal recording row IDs and committed Event upper row ID whenever a generic diagnostic receives the callback argument.

This is an active boundary, not an unused model: Event-store and outward runtime signals construct and deliver it, and it intentionally carries up to 32 changed recording IDs (`ViewerEventStore.swift:249-299,1093-1103`; `ViewerStoreCoordinator.swift:1261-1273`). The Round 9 store reflection regression checks the signal owner among the operational roots, but never reflects a populated `ViewerStoreChangeSnapshot` (`ViewerStoreTests.swift:10-67`). The modified capability requires every description, interpolation, and reflection helper to exclude installation/correlation identifiers and Event metadata values (`viewer-multidevice-flow-control/spec.md:7-11`). The operator guide also says the snapshot carries changed recording IDs and then claims coalescing retains no identities; that wording does not distinguish the intentionally retained internal database identities from forbidden peer identity (`Documentation/Viewer-Local-Store.md:47-53`).

A read-only Swift language probe confirmed the synthesized representation shape: a structurally equivalent value with IDs `101`, `202`, and upper row ID `303` emitted all three numbers through `String(describing:)`, `String(reflecting:)`, and direct mirror children. The first probe used the sandbox-inaccessible default module cache and executed no program; the identical retry with an isolated `/tmp` module cache succeeded.

Required resolution:

- Give `ViewerStoreChangeSnapshot` a closed description/debug description and a content-free or explicitly safe mirror. At most a bounded changed-recording count and closed store state may be exposed; recording row IDs and the Event upper row ID must remain available to the callback consumer but absent from diagnostics.
- Add a regression with distinctive nonzero recording/Event row IDs that covers description, debug description, `String(reflecting:)`, interpolation, and mirror children for the populated callback value itself, not only `ViewerStoreStatusSignal`.
- Clarify the operator guide so it accurately states that the in-memory callback retains bounded internal database row identities for refresh while generic diagnostics and presentation retain no such identities and no peer/Event content.

## Round 8 Finding Disposition

- `NW-ISPD8-001`: resolved for every owner explicitly reported. `WireHello` and the admission/session/store/SQLite/query/export roots now expose closed diagnostics, and the new real-object tests cover the previously missing sensitive ownership paths. The adjacent callback-value gap is a fresh issue recorded as `NW-ISPD9-001`.
- `NW-LSS-IMPL-R8-ARCH-001`: resolved. Direct writer failure classification now runs from the serialized SQLite failure edge before the writer turn is released, while operation-local outcomes remain nonpoisoning.
- `NW-LSS-IMPL-R8-ARCH-002`: resolved. Relay transitions have monotonic sequences, publication is ordered, and Event-store/ingress observers reject delayed transitions.
- `NW-LSS-IMPL-R8-ARCH-003`: resolved. Maintenance work owns a lifecycle generation, scheduled failures reach the authoritative state owner, runtime end invalidates recovery before terminal flush, and close waits for maintenance ownership before pool closure.
- `NW-LSS-IMPL-R8-CT-001`: resolved. Unpin, confirmed deletion, and improving settings changes capture a permit before work and can complete only that same failed generation; a newer failure rejects the older completion.

## Rechecked Boundaries Without Additional Findings

- Direct Event-store and scheduled maintenance failures publish their classified state before another writer can validate an old-generation authorization. Capacity recovery remains one bounded generation-bound campaign.
- Recovery permits and nonrecovering mutation authorization preserve the approved matrix without allowing rename, annotation, pin, ordinary cleanup, capacity reduction, or longer retention to reopen ingress.
- Maintenance dirty successors retain their original permit; runtime end invalidates pending publication, performs one terminal flush, and closes the pool only after maintenance and writer ownership quiesce.
- Event preparation, ingress, session queues, handoff, status delivery, cleanup campaigns, query pages, export pages, and retry ownership remain bounded. No task-per-Event, automatic polling retry, or unbounded in-memory result/alias map was introduced.
- SQLite uses three serial Viewer-only connections, bounded progress/cancellation, parameterized inputs, checked arithmetic, defensive/untrusted-schema settings, memory-only temporary storage, owner-only nonsymlink files, and a physical-volume reserve distinct from logical quota.
- Export retains the original temporary and parent descriptors, verifies file/parent identity, commits with descriptor-relative `renameat`, preserves the prior destination on every reported pre-commit failure, and treats post-rename directory synchronization as best effort without claiming rollback.
- The live filesystem audit remains applicable to unchanged paths and file lifecycle. It observed owner-only main/WAL/SHM artifacts, restored the exact prior store identity, removed the audit store and marker, and left no named residue.
- Documentation accurately discloses that local SQLite and JSON exports receive no NearWire application-layer at-rest encryption; FileVault is not detected or guaranteed; secure deletion is defense in depth; aliases are pseudonyms; and exports are outside Viewer quota/retention and may be synchronized or backed up.
- The privacy manifest remains consistent with the existing local `UserDefaults` and device-correlation behavior, and the final built manifest is byte-identical to the checked-in resource. Root package/podspec boundaries, Swift 5 language mode, iOS 16/macOS 13 support, system SQLite linkage, no third-party Core/SDK runtime dependency, and CocoaPods validation have current saved evidence.

## Fresh Validation and Evidence Basis

Fresh read-only checks on the reviewed tree produced:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches

find . \( -name Package.swift -o -name '*.podspec' \) -print
./NearWire.podspec
./Package.swift
```

The review also used the saved Round 9 results: 73 Viewer store tests with one explicit live-resource-audit skip and zero failures; the final unsigned Viewer run of 154 tests with one explicit live-audit skip and zero failures; 536 Swift package tests with seven existing environment-dependent skips and zero failures; successful CocoaPods validation; system SQLite linkage; and byte-identical built privacy-manifest inspection. The two configured-signing tests were excluded and are not counted as passing or skipped. The remaining finding is source- and callback-boundary-based and is not covered by the current reflection matrix.

## Unresolved Count

**One actionable finding remains unresolved: zero high and one medium. Approval is withheld.**
