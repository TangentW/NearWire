# Independent Implementation Review — Round 9 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, 0 Low.**

Round 8 remediation resolves the reported writer-edge failure window, reordered relay delivery, newer-failure recovery race, scheduled-maintenance failure classification, and shutdown lifecycle race in their tested forms. One recovery-ordering defect remains: a settings-recovery permit is bound to the store failure generation but not to the settings request that justified it. A later nonrecovering settings change can supersede the improving change without invalidating either a queued or already-running recovery permit, allowing the obsolete request to reopen automatic writes.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to the goal-level `release-hardening` change. They are neither findings nor represented as passing evidence here.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the current production, tests, documentation, packaging, and evidence change; all three Round 8 implementation-review reports; `implementation-remediation-round8.md`; and `implementation-validation-round9.md`.

The review retraced recovery-permit capture before unpin, manual deletion, and settings maintenance; intervening newer failures; nonrecovering metadata and cleanup mutation; direct and scheduled writer-edge failure classification; reversed relay delivery; dirty maintenance successors; runtime-end/close ordering; finite terminal flush behavior; deterministic test seams; skip accounting; and saved-result accuracy. The wider store change was also rescanned for regression in ingress ownership, drop persistence, quota/reclaim, query/export, bounded work, and protocol/store authority separation.

## Round 8 Finding Disposition

### Direct failure publication before writer release — resolved

`ViewerSQLiteConnection.run` now invokes its failure handler on the serialized connection queue before the queue turn returns. `ViewerEventStore.writeTransaction` classifies a terminal storage/capacity failure at that edge, advances the authoritative relay generation, and only then permits the next queued writer turn. `writeNotAuthorized` and `staleObservation` remain operation-local. Capacity recovery captures the newly failed generation, performs one bounded campaign, and either completes that exact permit or leaves/advances the failed state.

The deterministic direct-writer test blocks the first writer, queues a second already-ticketed writer, injects failure, and proves the second writer reaches neither the injected write gate nor SQLite mutation until an approved recovery creates a new generation.

Evidence: `ViewerSQLite.swift:279-325`; `ViewerEventStore.swift:1480-1578`; `ViewerStoreTests.swift:3638-3711`.

### Ordered relay transitions — resolved

Relay mutation and observer publication are serialized by `publicationLock`, and each published transition carries a monotonically increasing sequence. Event-store presentation and ingress reject an older sequence. Consequently, delayed recovery/failure callbacks cannot overwrite a later authoritative transition, and both surfaces converge on the relay state. The regression explicitly applies stale callbacks after failure and recovery and checks relay state, public status, admission/flush behavior, and automatic ticket availability.

Evidence: `ViewerEventStore.swift:1598-1613,1840-1853,2012-2179`; `ViewerStoreTests.swift:73-101`.

### Recovery permits and nonrecovering mutations — resolved for intervening failure generations

Unpin and manual deletion capture a permit before work, validate it on the serialized writer, and complete only the same permit after a successful commit. Settings maintenance captures its permit before queueing and carries it through each campaign writer turn. Rename, annotation, pin, and ordinary cleanup use automatic authorization while available or a generation-bound `nonRecoveringMutation` permit while failed; they do not call recovery completion.

The unpin, manual-delete, and settings tests block after successful work but before completion, inject a newer failure generation, and prove the older permit cannot reopen it. The sequential recovery matrix confirms nonrecovering operations leave both `writeFailed` and `capacityPaused` intact. Finding `NW-LSS-IMPL-R9-CT-001` is distinct: a later settings value does not advance the store failure generation, so it can supersede the reason for recovery without invalidating the permit.

Evidence: `ViewerStoreMaintenance.swift:326-380,458-529,1030-1120`; `ViewerEventStore.swift:2069-2169`; `ViewerStoreTests.swift:3787-4031`.

### Scheduled maintenance and shutdown ownership — resolved in the reported lifecycle race

Scheduled writer turns validate one campaign authorization and classify genuine storage/capacity failure before releasing the writer. The maintenance owner carries a lifecycle generation, invalidates recovery authority and dirty successors in `runtimeEnded`, rechecks lifecycle both before and after the recovery-publication seam, and synchronously drains its serial maintenance queue before pool close. Existing coordinator shutdown tests continue to prove one failed terminal flush, no retry of an already failed prefix, finite capacity failure, and next-open orphan reconciliation.

The focused scheduled-failure, dirty-successor, and in-flight runtime-end tests exercise the new owner seams. The remaining finding does not concern runtime shutdown; it concerns two live settings edits within the same valid lifecycle generation.

Evidence: `ViewerStoreMaintenance.swift:915-943,1150-1360`; `ViewerStoreCoordinator.swift:645-723`; `ViewerStoreTests.swift:3987-4111,4350-4481`.

## Finding

### NW-LSS-IMPL-R9-CT-001 — Medium — A superseded settings-recovery request can still reopen the store

`ViewerStoreRuntime.saveConfiguration` classifies each edit only against the immediately previous configuration. It requests `.settingsChanged` recovery for an increase in capacity or decrease in retention, and passes no recovery action for a capacity decrease, retention increase, or exact reversion. `ViewerStoreMaintenanceOwner.trigger` converts an improving edit into a permit for the current failed relay generation.

That permit is not associated with a settings revision, and later settings edits do not invalidate it:

- If another campaign is already scheduled, an improving settings edit stores its permit in `pendingRecoveryPermit`. A later nonrecovering settings edit sets `dirty` but, because its permit is `nil`, line 1205 leaves the older pending permit intact. The dirty successor therefore runs with the obsolete permit and the newest configuration, and a no-work/successful campaign completes the old permit and publishes `available`.
- If the improving settings campaign is already running, a later nonrecovering settings edit only marks a dirty successor. It does not change the running campaign's lifecycle generation or recovery permit. The running campaign can pass both lifecycle checks and complete the obsolete permit before the nonrecovering successor runs. That successor has no authority to restore the prior failed state.

A concrete sequence is: the store is `capacityPaused`; capacity is increased and captures permit G; before publication, capacity is restored to its original failed value (or retention is increased so the final change is nonrecovering); the older campaign completes G and reopens automatic ingress even though the setting that justified recovery is no longer current. This is not prevented by the relay generation check because neither settings edit is a store failure transition.

`testDirtySettingsRecoverySuccessorRetainsItsOriginalPermit` covers one improving settings request queued behind a normal threshold campaign. It does not issue a later settings request with `recoveryAction: nil`. `testRuntimeEndInvalidatesInFlightMaintenanceRecoveryBeforePublication` invalidates the lifecycle through shutdown, not through a newer live settings edit. Thus the current deterministic matrix misses both queued and already-running supersession.

Required remediation:

1. Give settings requests an owner-local monotonically increasing revision (or equivalent opaque identity) and bind recovery eligibility to the exact revision/configuration that justified it.
2. A newer `.settingsChanged` trigger must replace the pending settings recovery decision even when the new permit is `nil`; it must also invalidate recovery completion for an older already-running settings campaign without cancelling unrelated bounded cleanup ownership.
3. Immediately before completing settings recovery, verify that the captured settings revision is still current and that its recovery-eligible change has not been superseded. A stale campaign may finish its bounded maintenance work but must not publish `available`.
4. Add deterministic tests for both forms: (a) an improving settings permit queued behind a blocked campaign, then superseded by a nonrecovering/reverting edit; and (b) an improving campaign blocked at the publication seam, then superseded before release. Assert the relay/public status remain failed, ingress stays stopped, no automatic ticket or post-campaign drain is authorized, and a later current improving edit can recover exactly once.

Evidence: `ViewerStoreCoordinator.swift:1278-1288`; `ViewerStoreMaintenance.swift:1192-1218,1305-1358`; `ViewerStoreTests.swift:3987-4111`.

## Fresh Validation and Evidence Audit

### OpenSpec and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

### Fresh ViewerStore regression

The repository's arm64/module-cache command executed all 73 `ViewerStoreTests`: 72 passed, the explicit opt-in live Application Support audit was skipped, and zero failed. Legacy result-bundle inspection independently reports `testsCount: 73`, `testsSkippedCount: 1`, and `status: succeeded`:

```text
/tmp/NearWireViewerRound9CorrectnessReview/Logs/Test/Test-NearWireViewer-2026.07.13_11-53-47-+0800.xcresult
```

The skip source is `testOptInLiveApplicationSupportArtifactsWhileViewerStoreIsOpen`, guarded by `NEARWIRE_RUN_LIVE_STORE_AUDIT`; it is not represented as a pass.

### Fresh Swift package regression

The current Round 9 `--disable-sandbox --skip-build` command independently completed during this review:

```text
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
exit 0
```

The seven environment-dependent skips are not represented as passes.

### Saved complete Viewer evidence

The saved final bundle exists, and legacy result inspection confirms 154 total tests with one skip. This agrees with `implementation-validation-round9.md`; the validation report accurately states that its newer summary parser could not create a sandbox cache and does not claim that parser as evidence. The retained `xcodebuild` result reports zero failures. The two configured-signing tests were explicitly excluded and are not included in the total or skip count.

```text
/tmp/NearWireViewerRound9FinalDerived/Logs/Test/Test-NearWireViewer-2026.07.13_11-47-32-+0800.xcresult
testsCount: 154
testsSkippedCount: 1
```

## Completion Gate

Round 9 correctness/testing approval requires remediation of `NW-LSS-IMPL-R9-CT-001`, fresh focused and complete validation evidence, and a new independent correctness/testing review reporting exactly zero unresolved actionable findings.
