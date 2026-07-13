# Implementation Review Round 4 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined AGENTS.md, the active `viewer-local-store-search` proposal, design, capability specifications, tasks, current production and test source, `Documentation/Viewer-Local-Store.md`, the complete current change evidence, the Round 3 security/performance/documentation report, `implementation-remediation-round3.md`, `resource-filesystem-audit-round4.md`, and `implementation-validation-round4.md`. Production, test, specification, task, and operator-documentation files were not modified.

The review rechecked all four Round 3 findings and searched for new security, resource-bound, privacy, filesystem, reflection, and documentation/evidence defects. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to `release-hardening` and are not findings.

## Verdict

**Not approved. Three actionable medium-severity findings remain.**

## Findings

### NW-ISPD4-001 — Medium — Maintenance requires the 41-MiB worst-case reserve before every turn, blocking lower-cost recovery

The disk guard itself now correctly implements checked `64 MiB + plannedBytes` admission, and ordinary Event and structural transactions pass their computed plans. Maintenance, however, performs one unconditional guard with the 41-MiB oversized-reclaim maximum before it determines which operation the turn will execute (`ViewerStoreMaintenance.swift:200-233`). Consequently, every tombstone selection, normal reclaim, passive checkpoint, incremental-vacuum step, and even a no-work inspection requires at least 105 MiB available.

This creates a recovery dead zone. For example, with 80 MiB available, a normal write that needs more than 16 MiB correctly pauses, but maintenance cannot reach the passive checkpoint or 64-page incremental vacuum that may release physical space. The implementation's own checkpoint guard is only the 64-MiB floor (`ViewerStoreMaintenance.swift:750-770`), and the operator contract says checkpoint/free-page turns require that floor (`Documentation/Viewer-Local-Store.md:37-39`), but the outer 41-MiB reservation prevents those branches from running. The current boundary test calls `ViewerStoreDiskGuard` directly for three independent plans (`ViewerStoreTests.swift:2294-2320`); it does not prove that a maintenance campaign selects an action-specific plan or makes bounded recovery progress below 105 MiB.

Required resolution:

- Determine the next bounded mutation before physical admission and apply only its checked plan: exact tombstone selection, normal/oversize reclaim, checkpoint, or incremental vacuum.
- Permit read-only/no-work inspection and the documented 64-MiB checkpoint/free-page path without reserving the unrelated 41-MiB reclaim maximum.
- Add integration tests at `64 MiB + epsilon`, below `64 MiB + 41 MiB`, proving low-cost recovery can progress while an oversized reclaim still fails closed unless its full reserve exists.

### NW-ISPD4-002 — Medium — Direct Event journal carriers still expose sensitive content through synthesized reflection

Round 3 remediation closes reflection for prepared Events and the query/compiler/result models. The same sensitive Event values still cross the store boundary in types that retain synthesized reflection: `ViewerDownlinkJournalEvent` directly stores `EventEnvelope` (`ViewerMultiDeviceSession.swift:83-86`), `WireReceivedEvent` directly stores `EventEnvelope` (`WireEventPayloads.swift:341-346`), and `ViewerStructuralObservation` stores raw policy JSON, drop reason, and gap metadata (`ViewerEventStore.swift:126-155`). None implements a closed custom description/debug description/mirror.

Generic diagnostics, failed assertion interpolation, `String(reflecting:)`, or debugger mirrors can therefore traverse Event type/content/metadata and policy/sample values. That conflicts with the modified flow-control requirement that every description, debug description, reflection helper, interpolation, and diagnostic surface exclude those values (`viewer-multidevice-flow-control/spec.md:7-11`). The two reflection regressions cover `ViewerPreparedEventObservation` and query/summary models only (`ViewerStoreTests.swift:386-430,515-553`); they never exercise the journal carriers or structural observation enum.

Required resolution:

- Give every journal/structural carrier that can hold an Event or arbitrary metadata closed redacted `CustomStringConvertible`, `CustomDebugStringConvertible`, and `CustomReflectable` behavior, or wrap the sensitive payload in a deliberately nonreflecting owner.
- Add table-driven `String(describing:)`, `String(reflecting:)`, `Mirror`, interpolation/error, and log-surface tests for uplink, downlink, policy, drop, and gap carriers using unmistakable secret fixtures.

### NW-ISPD4-003 — Medium — The Round 4 audit still does not prove live app-container inspection or incremental-vacuum footprint reclamation

Round 4 materially improves the resource evidence: it records 1,000 sustained writes and WAL allocation, a near-maximum Event, process-level peak memory, active/closed temp-store permissions, export substitutions, system SQLite linkage, the built privacy manifest, both root distribution manifests, and current unsigned regressions. It does not complete two claims that task 7.5 and the earlier finding required.

First, the permission tests construct paths under a test temporary directory (`ViewerStoreTests.swift:1308-1358,2354-2360`), not the running Viewer's Application Support container. No saved command launches or opens the built Viewer and inspects its actual container main/WAL/SHM/journal/temp artifacts. Second, the audit contains no before/after allocated main-database footprint or free-list measurement for `PRAGMA incremental_vacuum(64)`; the implementation only checks that `freelist_count` decreases (`ViewerStoreMaintenance.swift:774-782`), and no test invokes that path. `resource-filesystem-audit-round4.md` therefore reports implementation inspection rather than measured incremental-vacuum evidence, while `tasks.md:38-42` marks the app-container and resource gate complete.

Required resolution:

- Inspect the built Viewer's actual Application Support directory while WAL is active and after a clean close, recording exact paths, file types, modes, and sidecar lifecycle without capturing sensitive contents.
- Add a deterministic free-page fixture and record before/after `freelist_count` plus allocated main/WAL footprint for one bounded incremental-vacuum turn, including failure and low-capacity behavior.
- Amend the audit with exact commands/results and keep task 7.5 checked only after both requirements have current-tree evidence.

## Round 3 Finding Disposition

- `NW-ISPD3-001`: the floor-plus-plan guard, checked arithmetic, and transaction planning are implemented. The action-selection problem in `NW-ISPD4-001` remains a distinct maintenance liveness defect.
- `NW-ISPD3-002`: resolved. Export retains the original temporary and parent descriptors, validates identities, uses descriptor-relative replacement, and has substitution/failure regressions. No new actionable export-path finding remains within the documented local-user threat model.
- `NW-ISPD3-003`: query/compiler/result reflection is resolved, but direct journal and structural carriers remain open as `NW-ISPD4-002`.
- `NW-ISPD3-004`: most resource, distribution, and filesystem evidence is now current; the two remaining proof gaps are captured by `NW-ISPD4-003`.

## Privacy Recheck

The Viewer target is macOS-only. Apple's current [privacy manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) states that Required Reason API declarations apply to iOS, iPadOS, tvOS, visionOS, and watchOS, not macOS. Although Apple's [accessed API category reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) classifies `volumeAvailableCapacityKey` as Disk Space and `stat`/`fstat`/`fstatat`/`lstat` as File Timestamp on covered platforms, their absence from this macOS Viewer's manifest is not reported as a defect. The saved built-manifest inspection correctly records the current UserDefaults and Device ID declarations; signing remains deferred as stated above.

## Validation Basis

This review used the exact current-tree results saved in `implementation-validation-round4.md` and `resource-filesystem-audit-round4.md`; it did not duplicate the already recorded 121-test unsigned Viewer run or 531-test root Swift package run. Source-level inspection was used where the finding concerns an untested branch or an evidence claim.

## Unresolved Count

**Three actionable findings remain unresolved: zero high and three medium. Approval is withheld.**
