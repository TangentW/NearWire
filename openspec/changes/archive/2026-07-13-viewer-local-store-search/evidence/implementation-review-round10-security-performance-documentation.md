# Implementation Review Round 10 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined `AGENTS.md`; the complete current `viewer-local-store-search` proposal, design, capability specifications, and task plan; the current production, test, packaging, privacy-resource, operator-documentation, and evidence tree; all three Round 9 implementation-review reports; `implementation-remediation-round9.md`; `implementation-validation-round10.md`; and the applicable live resource/filesystem audit. It retraced every Round 9 finding and re-audited writer-first SQLite bootstrap and failure cleanup, populated `ViewerStoreChangeSnapshot` diagnostics, the complete sensitive reflection/ownership chain, filesystem and export identity, queue/task/work/memory bounds, runtime recovery claims, settings-revision supersession, maintenance quiescence and terminal shutdown, privacy/resource/package boundaries, and documentation accuracy.

Production, test, specification, task, packaging, and operator-documentation files were not modified. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to goal-level `release-hardening`; they are neither findings nor passing results in this report.

## Verdict

**Not approved. Exactly one actionable medium-severity finding remains: zero high, one medium, and zero low.**

## Finding

### NW-ISPD10-001 — Medium — The claimed deterministic recovery regression still races lifecycle-queue admission

`implementation-remediation-round9.md` says that `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork` replaced its generic synchronization with an exact one-shot semaphore, and `implementation-validation-round10.md` says the final seven-test combination passed after that correction. The current test does contain a failure-consumption semaphore, but that semaphore observes only `OneShotViewerStoreFault.check()` after recovery work has already been accepted. It does not establish that the recovery request can enter the bounded lifecycle queue.

The setup blocks the first runtime write and then offers the same session 40 times (`ViewerStoreTests.swift:1190-1213`). The pipeline permits only 36 lifecycle/structural reservations (`ViewerEventStore.swift:1674-1705`). When the blocked write is released, `waitUntil { runtime.status().state == .unavailable }` may return as soon as relay failure publishes, before the first reservation has unwound and before the queued lifecycle prefix has drained (`ViewerStoreTests.swift:1213-1217`). The immediate `runtime.retryStorage()` can therefore be rejected at `ViewerJournalPipelineBudget.reserve`/`ViewerJournalPreparationQueue.offer` without ever reaching the armed one-shot fault (`ViewerStoreCoordinator.swift:668-686,1646-1703`). Waiting on the new fault semaphore then times out. The later assertions consequently observe no recovered gap or device.

The fresh review reran the exact seven-test command recorded in `implementation-validation-round10.md`. Six tests passed, but this test failed with the same four assertions that the validation document attributes to the pre-correction attempt:

```text
ViewerStoreTests.swift:1218: failure semaphore timedOut instead of success
ViewerStoreTests.swift:4928: waitUntil final condition failed
ViewerStoreTests.swift:1233: storageUnavailable gap count 0 instead of 5
ViewerStoreTests.swift:1240: durable device count 0 instead of 1

Selected tests: 7 executed, 4 failures
** TEST FAILED **
/tmp/NearWireViewerRound10SPD/Logs/Test/Test-NearWireViewer-2026.07.13_12-36-45-+0800.xcresult
```

An immediate isolated rerun of only `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork` failed identically, including the five-second semaphore timeout:

```text
Selected tests: 1 executed, 4 failures
** TEST FAILED **
/tmp/NearWireViewerRound10SPD/Logs/Test/Test-NearWireViewer-2026.07.13_12-37-37-+0800.xcresult
```

This does not by itself prove that the completion-owned production recovery implementation loses the claim. It does prove that the regression and the saved Round 10 validation cannot currently distinguish a rejected retry admission from the intended injected materialization failure, so the claimed deterministic evidence for the Round 9 recovery remediation is not reproducible on the current tree.

Required resolution:

- Establish an exact test synchronization point proving that the saturated lifecycle prefix has released enough ownership for the intended recovery request, or add a bounded test seam that signals recovery-work admission, before arming/expecting the materialization fault.
- Assert separately that recovery work was admitted, that the intended fault was consumed, that completion merged the exact claimed count, and that the following admitted retry durably owns the expected gap and one live device. Do not use store status alone as queue-quiescence evidence.
- Rerun the exact focused combination and the complete Viewer suite from the corrected current tree, then replace the inaccurate deterministic-pass claim in `implementation-validation-round10.md` with the fresh exact results.

## Round 9 Finding Disposition

- `NW-LSS-IMPL-R9-ARCH-001`: the production shutdown ordering is resolved. Runtime end invalidates maintenance publication and successors, the maintenance queue reaches a serial barrier, and the terminal ingress flush begins only afterward. The focused shutdown regression passed in the fresh run before the unrelated recovery test failed.
- `NW-LSS-IMPL-R9-ARCH-002`: resolved. Pool construction opens the writer, completes migration plus writer/schema acceptance, and only then opens the two readers. Local connection values unwind on construction failure. The focused construction-order/rejection regression passed freshly.
- `NW-LSS-IMPL-R9-ARCH-003`: the source now retains a generation-bound in-flight missed-observation claim and completes it only from the materialization callback. Fresh-coordinator recovery passed. The same-coordinator evidence remains unaccepted only because `NW-ISPD10-001` prevents the test from deterministically reaching its intended failure edge.
- `NW-LSS-IMPL-R9-CT-001`: resolved. Settings decisions carry a serialized revision, a newer nonrecovering edit replaces pending recovery authority, and running publication rechecks the revision. Both queued and running supersession regressions passed freshly.
- `NW-ISPD9-001`: resolved. A populated `ViewerStoreChangeSnapshot` keeps exact bounded internal IDs for its trusted callback consumer while description, debug description, interpolation, reflected string, and direct mirror children are content-free. The focused populated-value regression passed freshly, and the operator guide now distinguishes retained internal refresh IDs from diagnostic and peer-identity disclosure.

## Rechecked Boundaries Without Additional Findings

- The complete Event/wire/admission/session/store/SQLite/query/export/status owner chain retains closed descriptions and mirrors. The populated change-snapshot leaf is now covered directly; no current generic diagnostic path exposes its internal row IDs or Event content.
- SQLite bootstrap secures the directory and known artifacts, opens only the writer before schema acceptance, probes the accepted writer and both later read-only connections, and relies on scoped connection ownership plus explicit close for failure unwind. Unknown or incomplete schemas fail closed without automatic deletion or recreation.
- Event preparation, shared pipeline ownership, ingress, structural lanes, maintenance campaigns, query/export pages, status delivery, retry claims, and shutdown work remain count/byte/task/time bounded. SQLite status/query work has a generation-bound VM/time budget; no task-per-Event, automatic retry loop, unbounded result set, or alias map was introduced.
- Runtime recovery moves missed observations into a generation-bound claim, saturating-merges a failed current claim, and invalidates obsolete callbacks on runtime replacement/end/close. Maintenance shutdown invalidates queued successors and reaches quiescence before one finite flush.
- SQLite inputs remain parameter-bound and arithmetically checked. Store files remain owner-only and nonsymlink-validated. Export retains the original temporary and parent descriptors, verifies inode/owner/mode/link/parent identity, commits with descriptor-relative `renameat`, and preserves the prior destination on every reported pre-commit failure.
- The applicable live filesystem audit observed owner-only main/WAL/SHM artifacts, restored the exact prior store identity, removed the audit store and marker, and left no named residue. Round 9-to-10 production changes did not alter those paths or lifecycle rules.
- Documentation accurately states that local SQLite and JSON exports receive no NearWire application-layer at-rest encryption; FileVault is outside NearWire's guarantee; secure delete is defense in depth; aliases are pseudonyms; and exports are outside Viewer quota/retention and may be synchronized or backed up.
- The checked-in and built privacy manifests remain byte-identical according to the saved validation. The local capacity query does not transmit data. Root package/podspec boundaries, Swift 5 language mode, iOS 16/macOS 13 support, Viewer-only system SQLite linkage, and absence of third-party Core/SDK runtime dependencies remain intact.

## Fresh Validation and Evidence Basis

Fresh checks on the reviewed tree produced:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches

find . -name Package.swift -o -name '*.podspec'
./NearWire.podspec
./Package.swift

ruby -c NearWire.podspec
Syntax OK

xcrun swift-format lint --recursive Viewer/NearWireViewer/Store Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0; seven nonblocking trailing-closure suggestions and one test-only for-loop suggestion
```

Fresh hashes match the saved Round 10 values for `Package.swift`, `NearWire.podspec`, and the Viewer privacy manifest. The saved complete unsigned Viewer, Swift-package, system-SQLite linkage, built privacy-manifest, and applicable Round 9 CocoaPods evidence remain useful for unchanged inputs, but they cannot override the reproducible focused failure above. The configured-signing probes remain deferred and uncounted.

## Unresolved Count

**Exactly one actionable finding remains unresolved: zero high, one medium, and zero low. Approval is withheld.**
