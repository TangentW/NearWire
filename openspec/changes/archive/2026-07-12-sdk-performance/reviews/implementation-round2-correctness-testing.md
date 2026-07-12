# Implementation Round 2 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently re-reviewed the current active `sdk-performance` tree after Round 1 remediation: `AGENTS.md`, all active proposal/design/spec/task artifacts, every implementation Round 1 report, `evidence/implementation-round1-remediation.md`, current production and test sources, related Core and NearWire seams, Git status/diff, and current evidence summaries/raw logs. The review traced setup ownership, cancellation/error/stop/commit winner order, cleanup handle transfer, late outcomes, slow-setup activation, CPU/display epoch behavior, restart/resource counts, and the latest 50-test suite. This report is the only file modified.

## Findings

### 1. P2 / Medium — Race tests and checked coverage still overstate deterministic evidence

**Confidence: 10/10**

Several tests described as deterministic use a fixed twenty `Task.yield()` calls as a substitute for proof that the competing actor call reached the intended phase. In the late-unknown-error case, the test spawns a second waiter, yields, cancels it, and releases setup without any receipt proving that the waiter joined Starting (`SDK/Tests/NearWirePerformanceTests/PerformanceMonitorTests.swift:442-454`). If it has not entered, cancellation is merely pre-entry cancellation and cannot establish the shared-attempt winner. The typed-error stop test likewise does not prove stop installed Stopping before releasing setup (`PerformanceMonitorTests.swift:620-623`), and the failure-cleanup override does not prove stop changed the pending target before cleanup is opened (`PerformanceMonitorTests.swift:650-655`). These tests may fail under a different schedule rather than deterministically exercise the intended order.

Some cleanup-start tests can also pass without proving entry. For example, the successful restart-during-explicit-cleanup test checks that the predecessor lease count remains one before opening cleanup, but that result is identical if the restart Task has not run yet (`PerformanceMonitorTests.swift:788-813`). The analogous failure-cleanup test has the same limitation (`PerformanceMonitorTests.swift:715-746`). They establish the eventual successor result, not that a caller entered Stopping, waited there, and acquired nothing.

This matters to evidence truth. Tasks 4.2 and 4.3 remain checked as covering every winner order, stop-before-lease, stop-during-MainActor setup, stale setup/cleanup, managed/unmanaged battery interleavings, display teardown, and exact live Task/resource counters (`openspec/changes/sdk-performance/tasks.md:24-25`). The current suite does not contain exact arrival receipts or live counters for all of those named cases. The existing spec-to-evidence audit still says 40 tests and claims every requirement has evidence (`evidence/spec-to-evidence-audit.md:9-25,31-33`). It is appropriate that tasks 5.2 and 5.3 are now unchecked and that `final-validation.md` marks the old canonical run historical, but that does not make already checked test tasks accurate.

**Required resolution:** replace scheduler-yield assumptions with explicit test-only arrival/phase receipts that cannot release the opposing gate until the tested call is known to be waiting in the intended phase. Add exact counters or narrow the task wording for platform resources that are only smoke-tested. Uncheck tasks 4.2/4.3 until every listed case has the stated evidence, and regenerate the spec-to-evidence audit only after mapping each requirement/scenario to a concrete current test or an explicitly deferred later gate.

## Round 1 Items Verified Closed

- Starting now owns one setup Task, joined callers share one bounded outcome, cooperative cancellation reaches that Task, and typed/unknown setup errors arriving after invalidation resolve as cancellation with exact collector/lease cleanup.
- Cancellation versus run transfer now has one atomic winner: the monitor actor checks the exact Starting phase and calls `attempt.sealForCommit()` within the same non-suspending commit method immediately before installing Running (`SDK/Sources/NearWirePerformance/NearWirePerformanceMonitor.swift:167-193`). If cancellation wins the attempt lock, sealing fails; if sealing wins, Running commits in that actor turn. There is no worker-side seal/actor-hop gap (`SDK/Sources/NearWirePerformance/Internal/PerformanceRuntime.swift:211-228`).
- Prepared resource ownership remains with the setup worker until successful actor transfer; every observed pre-transfer failure stops the collector before releasing the lease.
- Slow setup is excluded from the first header epoch and CPU baseline. The five-second setup-delay test produces a one-second first header and the correct post-activation CPU calculation (`PerformanceMonitorTests.swift:506-550`). Slow collection is included in the following header without catch-up (`PerformanceMonitorTests.swift:43-68`).
- Display resources are prepared paused and reset/unpaused only at activation; the 1,000-cycle test proves 1,000 activations, 1,000 stops, no clock waiters, and zero remaining monitor leases.
- Successful start during slow explicit cleanup and cancellation while awaiting cleanup now have direct successor/resource assertions. The cancelled-Starting weak probe confirms no retention remains after the cancelled call completes.
- The focused evidence is fresh at 50 tests, the old canonical run is explicitly historical, and full validation/spec-to-evidence tasks 5.2 and 5.3 are correctly pending. The aggregate Xcode App privacy report remains assigned to the maintained Demo/release archive gate.

## Validation Performed

- `HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --disable-sandbox --filter NearWirePerformanceTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: **PASS**, 50 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.
- No production, test, specification, task, documentation, evidence, package, manifest, or prior review file was modified by this review.

## Verdict

**Implementation approval withheld. Exact unresolved actionable finding count: 1 Medium.**
