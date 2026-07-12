# Implementation Round 3 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently re-reviewed the current active `sdk-performance` implementation after Round 2: `AGENTS.md`, all active proposal/design/spec/task artifacts, implementation review reports, current production and test sources, related Core and NearWire seams, Git status/diff, and current evidence summaries. The review focused on the prior deterministic-testing finding, the two-stage activation/commit winner, setup and cleanup receipts, delayed setup/collection math, resource teardown, and whether the narrowed task/evidence claims are proportionate rather than maximal. This report is the only file modified.

## Findings

**Zero actionable findings.**

## Verification

### Lifecycle and cancellation winners

Starting owns one setup Task and one bounded shared outcome. The exact attempt lock now distinguishes pre-activation acquisition, activation authorization, cancellation, and committed transfer (`SDK/Sources/NearWirePerformance/Internal/PerformanceRuntime.swift:88-185`). The monitor actor authorizes activation only for the current Starting attempt and later performs the cancellation-versus-commit decision inside the exact actor phase before publishing Running (`SDK/Sources/NearWirePerformance/NearWirePerformanceMonitor.swift:177-210`). Cancellation after authorization but before commit sets the attempt cancelled, cancels the setup Task, makes `commitActivation()` fail, and leaves the setup worker responsible for stopping the prepared collector before releasing its lease. Stop also changes the actor phase before awaiting the same attempt receipt, so stale success/error completion cannot publish Running or affect a successor.

The existing run cleanup path remains sound: explicit and failure cleanup use the exact predecessor run Task as their barrier, public Failed is not published until collector stop and lease release complete, explicit stop can replace the pending target with Stopped, and a successor start cannot acquire resources until the predecessor Task receipt completes.

### Deterministic and proportionate testing

The fixed-count `Task.yield()` ordering assumptions identified in Round 2 are gone. `waitUntil` still yields between polls, but only while waiting for an explicit observable condition; it is not used as a guessed scheduler delay (`SDK/Tests/NearWirePerformanceTests/PerformanceTestSupport.swift:225-235`).

Critical shared-start tests now wait for the exact Starting waiter count before release or cancellation (`SDK/Tests/NearWirePerformanceTests/PerformanceMonitorTests.swift:290-370,413-463`). Stop-versus-setup-error, stop-during-setup, failure-cleanup override, and noncooperative submission tests wait until the monitor reports a Stopping target of Stopped before releasing the opposing dependency (`PerformanceMonitorTests.swift:552-662,808-840`). These observations prove that the intended actor transition occurred rather than merely that a Task was spawned.

Coverage is appropriately scoped for an internal optional metrics module. Deterministic fakes prove lifecycle winners, CPU/FPS/projection math, queue behavior, epoch/reset behavior, exact collector/lease teardown, and 1,000 start/stop activations. iOS smoke tests exercise the real display and battery path without pretending UIKit global resources expose reliable deterministic counters. Additional private phase machinery solely to observe every benign suspension would add complexity without materially improving confidence.

### Sampling and resource behavior

Resource preparation remains separate from activation. Display resources are prepared paused, activation establishes the fresh baseline after setup, and cancellation is rechecked before actor commit. The slow-setup test excludes five seconds of setup from the first one-second header and CPU calculation; the slow-collection test includes collection duration in the following header without catch-up. CPU successful-to-successful recovery, display callback formula/reset, unavailable precedence, saturated terminal-drop accounting, newest-one state streams, deinitialization, and macOS unsupported behavior remain consistent with the specification.

### Task and evidence truth

Tasks 4.2, 4.3, and 4.6 now describe the evidence actually present instead of claiming exhaustive platform counters or a parallel script-test framework (`openspec/changes/sdk-performance/tasks.md:24-28`). The interim spec-to-evidence audit identifies current focused evidence separately from the still-pending canonical packaging/full-suite/iOS evidence, and tasks 5.2/5.3 remain unchecked (`evidence/spec-to-evidence-audit.md:1-35`; `tasks.md:33-34`). The old canonical run is explicitly historical rather than represented as proof of the current tree (`evidence/final-validation.md:5-28`). This satisfies the required workflow without overstating completion.

## Validation Performed

- `HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --disable-sandbox --filter NearWirePerformanceTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: **PASS**, 51 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.
- Fixed-count `Task.yield()` ordering scan in Performance tests: **PASS**, no matches.
- No production, test, specification, task, documentation, evidence, package, manifest, or prior review file was modified by this review.

## Verdict

**Implementation correctness/testing approval granted. Exact unresolved actionable finding count: 0.**
