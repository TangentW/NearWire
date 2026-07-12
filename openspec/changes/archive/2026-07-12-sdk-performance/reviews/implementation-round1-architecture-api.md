# Implementation Review Round 1 — Architecture and API

Date: 2026-07-12

## Scope

Independently reviewed `AGENTS.md`, the complete active `sdk-performance` proposal, design, capability deltas, tasks, pre-implementation reviews and remediations, all implementation and test source under `SDK/Sources/NearWirePerformance` and `SDK/Tests/NearWirePerformance*`, the relevant Core schema and NearWire built-in/diagnostics path, root SwiftPM and CocoaPods manifests, validation scripts, changed documentation, Git status/diff, and every final evidence file including the raw logs. No production, test, specification, task, documentation, script, or evidence file was modified by this review.

## Findings

### P1 / High — Starting does not own or cancel the setup Task, and invalidation cannot guard the MainActor resource-acquisition continuation

**Confidence: 10/10**

The normative lifecycle requires Starting to hold one exact attempt token/task, requires cancellation by any waiter or stop to cancel the shared attempt, and requires every setup continuation to revalidate the token before its next acquisition (`specs/sdk-performance/spec.md:34-36`; `design.md:93-97`). The implementation instead stores only `PerformanceStartAttempt` in the phase (`NearWirePerformanceMonitor.swift:15-19`). The setup work runs directly in whichever caller owns `start()`, and `PerformanceStartAttempt.cancel()` only flips a locked Boolean (`PerformanceRuntime.swift:84-103`); it has no setup `Task` handle to cancel.

This is not only a representation difference. `performOwnedStart` checks the Boolean, captures an instant, and then awaits the complete collector factory (`NearWirePerformanceMonitor.swift:158-166`). The live factory crosses to MainActor (`PerformanceRuntime.swift:32-49`), where `Storage.init` creates and schedules a `CADisplayLink` and may claim the App-global battery switch (`PerformancePlatformSession.swift:53-71`). If stop or another Starting waiter cancels while that hop is suspended, the factory receives neither the attempt token nor Task cancellation. It may therefore acquire both external resources after the attempt was invalidated; only after the whole factory returns does the monitor notice the flag and tear them down. The same omission prevents a cancellation-cooperative factory from stopping promptly, so `stop()` can remain blocked on setup work that the lifecycle says it cancelled.

The deterministic setup test gates the whole fake factory and proves eventual cleanup, but it does not put a barrier immediately before each MainActor acquisition or assert that a cancellation-cooperative setup Task was cancelled. Task 3.1 and task 4.3 are therefore checked without their stated evidence.

**Required remediation:** make one internal setup Task the exact owner of the attempt and have stop, any Starting waiter cancellation, and teardown cancel that Task. Split or parameterize live collector construction so the exact attempt/cancellation gate is rechecked on MainActor before display-link creation and before battery claim. Keep partial handles task-owned and clean them once. Add deterministic cooperative-cancellation and pre-acquisition barriers proving that invalidation prevents later acquisitions, all joiners receive the same outcome, and stop returns only after exact partial cleanup.

### P2 / Medium — The initial sampling epoch and CPU timestamp are captured before asynchronous collector setup

**Confidence: 10/10**

The spec requires the fresh monotonic header epoch and collector baselines to be established after setup, immediately before Running commits (`specs/sdk-performance/spec.md:166`; `design.md:185`). The implementation captures `initialBoundary` before `await runtime.makeCollector` and passes that earlier instant both to collector construction and the run worker (`NearWirePerformanceMonitor.swift:161-172`). The live factory may wait on MainActor before it constructs `LivePerformanceCollectorSession`, whose initializer performs the actual initial CPU read.

Consequently, MainActor or factory delay is included in the first snapshot's `sampleIntervalMilliseconds` even though the first requested sampling sleep has not started. More importantly, the first CPU cumulative reading is paired with an instant captured before that reading and potentially well before collector construction, so the first computed CPU percentage can use an inflated elapsed denominator. The new ordering test correctly proves that each turn captures `sampledAt` before collector reads, but it does not cover this start/setup boundary.

**Required remediation:** construct fallible platform/session resources first, then establish the header epoch and prime collector baselines from one fresh instant immediately before the Running commit. This likely requires an unprimed collector plus an explicit internal prime/start operation rather than passing an old instant into the async factory. Add a deterministic slow-setup test that advances monotonic time during factory suspension and proves the first interval contains only the post-commit sampling period and the CPU baseline uses the post-setup instant.

### P2 / Medium — `NearWirePerformanceError` exposes an unapproved public conformance and member

**Confidence: 9/10**

The design's exact supported declaration lists `NearWirePerformanceError: Error, Equatable, Sendable` with only `code`, `field`, and `message` (`design.md:34-59`). The implementation additionally conforms it to `CustomStringConvertible` and exposes public `description` (`NearWirePerformanceError.swift:24-31`). That conformance/member is source-authored supported API and therefore part of the SemVer surface. SwiftPM/CocoaPods parity proves both distributions expose the same extra API; it does not prove that the extra API was approved. `Scripts/check-sdk-performance-structure.rb:29-56` currently encodes the implementation drift by expecting `public var description`, while the supported consumer fixture never exercises it.

**Required remediation:** remove the public conformance/member and keep any formatting internal, or explicitly amend and review the exact API contract, consumer fixtures, documentation, and compatibility inventory if this is intentionally supported. Under the current narrow-surface decision, removal is the smaller compliant change.

### P2 / Medium — Final raw evidence no longer represents the reviewed source and test tree

**Confidence: 10/10**

`evidence/final-validation.md:26` states that no production or test source changed after canonical run `20260712T091700Z-63876`, and its focused result records 40 tests (`final-validation.md:42-46`). The current tree contains the later `sampledAt` production ordering change plus `testWallAndMonotonicSampleBoundariesAreCapturedBeforeCollectorReads`, and a fresh local focused run now executes 41 tests. The canonical raw package log therefore proves the prior source, not the current implementation. In particular, the full iOS simulator, iOS 16 distributed-source, SwiftPM API/resource/symbol, CocoaPods parity/framework, and package audit results have not been recaptured for the final tree.

**Required remediation:** after resolving implementation findings, rerun the canonical evidence harness over the exact final tree, store the new raw logs, update counts/hashes and the final summary, and ensure the summary makes no post-run immutability claim contradicted by file history.

## Verified Decisions Without Findings

- The latest sampling loop captures both the monotonic boundary and `sampledAt` before collector reads, and the new focused ordering test passes.
- Failure cleanup uses one predecessor run Task as its barrier, retains public Running until task-owned cleanup completes, lets stop replace a pending Failed target with Stopped, gates successor start on task completion, and prevents the run worker from strongly retaining the monitor.
- `currentState` is actor-isolated and authoritative. The nonisolated stream hub is newest-one bounded, finishes on deinit, and holds only weak termination callbacks.
- The public monitor remains instance-based, the exact-`NearWire` lease is process-wide and token-protected, and the worker uses the ordinary built-in keep-latest queue rather than a transport or persistence side path.
- Platform-neutral schema remains in Core. Darwin, Mach, UIKit, and QuartzCore collector code remains under the optional SDK Performance target; no Viewer source changed and no third-party Core/SDK runtime dependency was introduced. macOS rejects start before lease or collector setup.
- SwiftPM and CocoaPods keep Performance optional, compile in Swift 5 language mode for iOS 16, isolate UIKit/QuartzCore to Performance, package separate base Device ID and Performance Data manifests, reject internal/snapshot facades, and produce normalized declaration parity.
- The revised privacy gate is architecturally correct for this library change: package-level source/built-manifest, complete-envelope, Required Reason source/symbol, and linkage audits are present now; the aggregate Xcode App privacy report is explicitly assigned to the maintained Demo and real release App archive rather than a temporary validation App (`specs/sdk-performance/spec.md:204-210`, `Documentation/SDK-Performance.md:131`, and `Documentation/Implementation-Roadmap.md:95-101`).

## Validation Performed by This Review

- Latest focused Performance suite with complete concurrency and warnings as errors: **PASS**, 41 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `ruby Scripts/check-sdk-performance-structure.rb`: **PASS**, while retaining the API-drift concern above.
- `git diff --check`: **PASS**.
- Canonical raw evidence: all recorded commands exited 0, but it is stale relative to the latest production/test changes as described in Finding 4.

## Verdict

**Implementation architecture/API approval withheld. Unresolved actionable finding count: 4 — one High and three Medium.**
