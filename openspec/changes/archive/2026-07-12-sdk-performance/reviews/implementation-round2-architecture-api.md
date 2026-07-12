# Implementation Review Round 2 — Architecture and API

Date: 2026-07-12

## Scope

Independently reviewed the current active `sdk-performance` tree, all three Round 1 implementation reports, `evidence/implementation-round1-remediation.md`, the current lifecycle/runtime/platform/collector implementation, all Performance tests including the latest three test-only additions, public API and boundary validators, tasks, final-validation status, spec-to-evidence audit, packaging manifests, and Git status/diff. This review specifically retraced setup Task ownership, weak retention, cancellation winners, acquisition gates, setup-to-run ownership transfer, activation epoch, public API removal, and evidence truthfulness. This report is the only file modified.

## Findings

### P2 / Medium — Platform activation and the initial epoch still precede the awaited actor commit

**Confidence: 9/10**

The latest shared-tree revision correctly moved `attempt.sealForCommit()` into `commitPreparedStart`, so phase validation, cancellation-versus-commit winner selection, resource transfer, run Task creation, and Running publication now occur in one actor turn (`NearWirePerformanceMonitor.swift:167-193`). A cancellation that acquires the attempt lock first rejects commit; a seal that wins is immediately followed by the Running transition without another suspension. The prior non-atomic seal concern is therefore resolved.

Activation remains outside that atomic turn. `PerformanceSetupWorker.run()` awaits `preparedCollector.activate(clock:)`, checks cancellation, and then performs a separate awaited call to `monitor.commitPreparedStart(...)` (`PerformanceRuntime.swift:211-224`). `LivePerformanceCollectorSession.activate` first awaits platform activation, then captures and primes the monotonic boundary (`PerformanceLiveCollector.swift:41-47`). On iOS, platform activation resets and unpauses the display link (`PerformancePlatformSession.swift:89-92,184-186`). Actor scheduling delay between activation/boundary capture and the Running commit is consequently included in the first header interval, and display callbacks may enter the first accumulator while public state and actor phase are still Stopped/Failed plus Starting. If cancellation or stop wins at actor commit, those callbacks are discarded during cleanup; if commit wins, they are attributed to a header interval that began before the monitor became Running.

This is narrower than the original five-second setup defect, which is fixed, but it still conflicts with the exact contract that the fresh epoch and collector baselines are established immediately before Running commits and that the observing interval belongs to the run (`specs/sdk-performance/spec.md:166`; `design.md:185,201`). The slow-setup test excludes factory delay but does not suspend the actor between activation and commit or verify display callback ownership across this boundary.

**Required remediation:** keep the display observer paused until the accepted actor commit and establish the run epoch at that same accepted boundary, or introduce a two-phase activation/finalization token whose timing semantics explicitly exclude the activation-to-finalization gap. Add a deterministic post-activation/pre-commit barrier proving first-header timing and display callback ownership when commit succeeds and when cancellation or stop wins.

### P2 / Medium — Checked test tasks and the spec-to-evidence audit still overstate current evidence

**Confidence: 10/10**

The remediation correctly changed task 5.2 and task 5.3 back to unchecked and `final-validation.md` now honestly labels the original canonical run as historical. However, tasks 4.2 and 4.3 remain checked as complete (`tasks.md:24-25`) even though the post-activation/pre-actor-commit interval above has no deterministic seam or test. Task 4.3 also claims stop during MainActor setup, exact live display/battery teardown counters, and no-generation-overlap evidence; the generic `performAcquisition` unit test proves the lock rejects work after cancellation or sealing, but it does not race cancellation against the actual MainActor `Storage.init` acquisition sites or count live `CADisplayLink` and battery-claim resources.

The current `spec-to-evidence-audit.md` is also not marked historical: it still cites a focused 40-test result and the original raw iOS logs, and concludes that no spec-to-evidence gap is known. The latest focused tree executes 50 tests, while the repository correctly acknowledges that complete canonical recapture is pending. Leaving this audit's unconditional conclusion beside an unchecked task 5.3 makes the evidence state internally contradictory.

**Required remediation:** leave tasks 4.2/4.3 unchecked or narrow their text until every listed scenario has concrete evidence; add the missing atomic-commit and live MainActor resource tests; and mark or replace the stale spec-to-evidence audit. After review remediation, run the planned canonical recapture and only then check 5.2/5.3 and restore a final no-gap audit with exact current test counts and raw-log references.

## Round 1 Finding Disposition

- **Owned setup Task and cancellation propagation:** substantially resolved. Starting installs one exact setup Task; owner and joiners await the same outcome; stop and waiter cancellation cancel that Task; late typed/unknown setup errors normalize to cancellation after invalidation.
- **Weak ownership and cleanup:** resolved. The setup worker holds only `PerformanceWeakMonitor`; lease and collector remain local setup-owned handles until successful actor transfer; every pre-transfer catch stops the collector before releasing the lease; cancelled Starting and Running weak-retention probes pass.
- **Per-acquisition gates:** implementation mechanism resolved. Actual display-link creation and battery claim execute inside the attempt lock and cannot begin after cancellation or sealing. The remaining test-evidence gap is recorded above.
- **Pre-commit collector leak:** resolved. Collector ownership is retained in setup locals until `commitPreparedStart` succeeds, and all failure/cancellation paths call `collector.stop()` before lease release.
- **Atomic commit seal:** resolved in the latest tree. `commitPreparedStart` performs phase validation and `sealForCommit()` synchronously before creating the run Task and publishing Running, so cancellation and commit have one exact lock/actor winner.
- **Post-setup epoch and CPU baseline:** the original long-setup defect is resolved. Collector construction is unprimed; activation after setup captures the boundary and primes CPU; a five-second setup delay yields a one-second first header and post-setup CPU pair. The narrower activation-to-commit interval remains Finding 1.
- **Public API drift:** resolved. `NearWirePerformanceError` no longer conforms to `CustomStringConvertible` and exposes no public `description`; the exact source validator was updated and its mutation suite passes.
- **Evidence freshness:** partially resolved. Historical versus current validation is now stated honestly and tasks 5.2/5.3 are unchecked pending recapture. The stale audit and overbroad checked test tasks remain Finding 2.

## Other Verified Architecture and API Boundaries

- Public Performance declarations remain exactly configuration, fixed safe error/code, lifecycle state, and actor monitor. Snapshot, metric, collector, clock, lease, setup/run worker, acquisition gate, and test seams remain internal.
- Failure-targeted and explicit cleanup still use one predecessor Task barrier, stop can override pending Failed with Stopped, successor start waits for cleanup, and run cleanup does not strongly retain the monitor.
- `currentState` remains actor-isolated and authoritative; the nonisolated newest-one stream hub retains no monitor and finishes on deinit.
- The exact-`NearWire` monitor lease, ordinary keep-latest built-in path, Core schema reuse, iOS-only collector placement, macOS unsupported path, zero third-party SDK dependency, and Viewer isolation remain intact.
- SwiftPM and CocoaPods continue to expose the same intended module surface and optional Performance isolation by source/manifests. Final regenerated API parity and packaging proof is appropriately pending under unchecked task 5.2.
- The library-versus-host-App privacy-report split remains coherent: current SDK artifacts own package-level manifest/source/symbol audits, while the aggregate Xcode App privacy report remains assigned to maintained Demo and release archives.

## Validation Performed by This Review

- Latest focused Performance suite with complete concurrency and warnings as errors: **PASS**, 50 tests, 0 failures.
- `ruby Scripts/check-sdk-performance-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.

## Verdict

**Implementation architecture/API approval withheld. Unresolved actionable finding count: 2 Medium.**
