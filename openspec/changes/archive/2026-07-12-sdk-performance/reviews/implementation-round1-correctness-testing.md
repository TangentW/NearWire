# Implementation Round 1 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently reviewed `AGENTS.md`, the complete active `sdk-performance` proposal, design, capability specification, tasks, prior review and remediation records, all current Performance production and test sources, the related Core snapshot schema and NearWire queue/diagnostic seams, current Git status and diff, and all saved validation evidence and raw logs. The review traced lifecycle generations and cleanup winners, sample-header ordering, CPU and FPS calculations, unavailable precedence, queue/drop projection, iOS and macOS behavior, resource bounds, packaging evidence, and evidence freshness. This report is the only file modified.

## Findings

### 1. P1 / High — Starting has no owned setup Task, and a late setup error can defeat an earlier cancellation

**Confidence: 10/10**

The approved lifecycle requires Starting to store one exact setup Task and requires cancellation by any Starting waiter or `stop()` to cancel that shared attempt, clean it, and make every waiter receive `CancellationError` (`design.md:93-97`; `specs/sdk-performance/spec.md:34-38`). The implementation instead stores only a `PerformanceStartAttempt` object in the phase (`SDK/Sources/NearWirePerformance/NearWirePerformanceMonitor.swift:15-20`) and executes `performOwnedStart` inline on whichever caller first entered `start()` (`NearWirePerformanceMonitor.swift:96-103`). `PerformanceStartAttempt.cancel()` only sets a Boolean (`SDK/Sources/NearWirePerformance/Internal/PerformanceRuntime.swift:84-103`); there is no setup Task handle to cancel or independently own cleanup.

This creates an observable wrong-winner race. If a waiter cancellation or `stop()` marks the attempt cancelled while `makeCollector` is suspended, and that setup then throws a typed or unknown error, the inner catch releases the lease and rethrows it (`NearWirePerformanceMonitor.swift:158-175`). The outer typed/unknown catches resolve the shared attempt as `NearWirePerformanceError` without first rechecking `attempt.isCancelled` (`NearWirePerformanceMonitor.swift:181-194`). Therefore all joined `start()` calls can receive `collectorSetupFailed` or another performance error even though cancellation invalidated the attempt first. The public state may still become Stopped through `finishStartAttempt`, so the thrown result and lifecycle winner disagree.

The missing owned Task also means `stop()` and deinitialization can only mark a noncooperative setup logically cancelled; they cannot deliver Swift task cancellation to a cooperative suspension. An in-flight actor call retains the monitor until that caller returns, so the Running-only weak deinitialization test does not establish the specified Starting deinitialization behavior. The existing cancellation tests release gates with successful collectors (`SDK/Tests/NearWirePerformanceTests/PerformanceMonitorTests.swift:293-385`), so neither the late-error winner nor deinitialization during setup is exercised.

**Required resolution:** make Starting own an exact setup Task/outcome receipt independently of any caller; have every joined caller await it; propagate shared cancellation to that Task; and make cancellation/token invalidation dominate every late setup success and error path. Add deterministic tests for typed and unknown setup failures arriving after waiter cancellation and after `stop()`, cooperative setup cancellation, deinitialization while setup is suspended with a weak monitor probe, and exact one-time cleanup/lease release for each winner.

### 2. P1 / High — The first header epoch and CPU/display baselines begin before asynchronous setup completes

**Confidence: 10/10**

The contract requires a successful start to establish a fresh monotonic header epoch and collector baselines immediately before Running commits, then sleep one full configured interval before the first turn (`specs/sdk-performance/spec.md:164-168`; `design.md:181-185`). The implementation captures `initialBoundary` before awaiting collector construction (`SDK/Sources/NearWirePerformance/NearWirePerformanceMonitor.swift:158-172`). Live collector construction first awaits MainActor platform creation, creates and schedules the display link during that setup (`SDK/Sources/NearWirePerformance/Internal/PerformancePlatformSession.swift:53-71`), and only afterward reads cumulative CPU time while assigning it the earlier `initialBoundary` (`SDK/Sources/NearWirePerformance/Internal/PerformanceLiveCollector.swift:25-39`). Commit does not re-arm the epoch, re-prime CPU, or reset display callbacks (`NearWirePerformanceMonitor.swift:207-230`).

Consequently, a delayed MainActor/setup continuation makes the first `sampleIntervalMilliseconds` include setup latency because the worker measures from that pre-setup boundary (`SDK/Sources/NearWirePerformance/Internal/PerformanceRuntime.swift:166-185`). The first CPU result pairs a later cumulative CPU reading with an earlier monotonic instant, distorting the denominator, and the first FPS interval may include callbacks observed before Running was committed. This violates both the header semantics and the successful-to-successful CPU timestamp pairing even though the newly corrected per-turn ordering now captures the wake boundary and `sampledAt` before collector reads (`PerformanceRuntime.swift:172-184`).

The normal first-turn test uses an immediately returned fake collector (`SDK/Tests/NearWirePerformanceTests/PerformanceMonitorTests.swift:7-41`), while slow setup tests stop or only assert Running after releasing setup and never sample the first post-setup turn (`PerformanceMonitorTests.swift:263-385`). They therefore cannot detect this error.

**Required resolution:** separate resource preparation from run activation. After all asynchronous setup succeeds and immediately before Running commits, capture one boundary, prime CPU with a reading taken at that boundary, and reset/arm the display accumulator; pass that exact epoch to the worker. Add a deterministic slow-setup test proving setup time is absent from the first header interval, CPU uses time-matched successful pairs, pre-Running callbacks are excluded, and restart creates a new epoch/baseline.

### 3. P2 / Medium — Checked test tasks and canonical evidence are not truthful for the current workspace

**Confidence: 10/10**

The saved canonical run predates the current `sampledAt` source and ordering-test changes, yet `final-validation.md:26` says that after the canonical run no production or test source changed. It also reports a final focused count of 40 tests (`final-validation.md:42-46`). A fresh independent execution of the exact focused command against the current workspace passed **41** tests with zero failures in 0.418 seconds; the added ordering test is at `SDK/Tests/NearWirePerformanceTests/PerformanceMonitorTests.swift:43-67`. Thus the raw iOS, SwiftPM packaging, and CocoaPods logs do not validate the exact current source tree, and the stated post-run change boundary is false.

The issue is broader than a stale count. Tasks 4.2 and 4.3 are checked as fully evidenced (`tasks.md:24-25`), and the spec-to-evidence audit claims complete lifecycle winner, slow-collection, restart-reset, managed/unmanaged battery-interleaving, display-teardown, stale-completion, and generation-overlap coverage (`evidence/spec-to-evidence-audit.md:9-19,31-33`). The current tests do not cover the cancellation-versus-late-setup-error race or slow-setup epoch defect above. They also do not provide the claimed owned setup/cleanup Task counters, deinitialization during Starting, successful restart during slow explicit cleanup, an exact live display-link teardown counter, or multi-claim live battery-registry interleavings. Passing tests cannot support checked evidence claims for scenarios they never execute.

**Required resolution:** uncheck or narrow every task whose stated evidence does not exist, add deterministic tests for the missing normative scenarios, then rerun the complete required validation harness on the final source tree. Save new raw logs and hashes, update exact platform/focused test counts, and make the spec-to-evidence audit map each scenario to a concrete test or an explicitly named later gate. Do not describe the current canonical run as final after source/test changes.

## Verified Areas Without Findings

- The current sampling turn captures the monotonic wake boundary and wall-clock `sampledAt` before collector reads; the new trace test verifies the wall-clock/collector order.
- CPU successful-to-successful recovery, non-finite/regression rebaselining, FPS `(count - 1) / (last - first)` math, accumulator reset, deterministic unavailable ordering/precedence, JSON-safe terminal-drop saturation, ordinary keep-latest coalescing, macOS unsupported behavior, and the current iOS best-effort smoke paths are internally consistent for the cases exercised.
- The latest privacy wording correctly treats the package audit as the SDK artifact check while preserving the aggregate Xcode App privacy report as a maintained Demo and release-hardening archive gate (`evidence/privacy-packaging-audit.md:37`; `design.md:211-224`; `tasks.md:33`).

## Validation Performed

- `HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --disable-sandbox --filter NearWirePerformanceTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: **PASS**, 41 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.
- Git status remains the expected uncommitted active-change workspace; no production, test, specification, task, documentation, evidence, package, or manifest file was modified by this review.

## Verdict

**Implementation approval withheld. Unresolved actionable finding count: 3 — two High and one Medium.**
