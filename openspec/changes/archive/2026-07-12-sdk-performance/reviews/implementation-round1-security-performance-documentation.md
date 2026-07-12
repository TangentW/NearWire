# Implementation Security, Performance, and Documentation Review — Round 1

## Scope

Independently reviewed `AGENTS.md`, the complete active `sdk-performance` proposal, design, delta specifications, tasks, pre-implementation reviews and remediation records, implementation and tests, root SwiftPM/CocoaPods manifests, validation scripts, public-consumer fixtures, documentation, `git status`/diff, all evidence summaries, and `evidence/raw`. The review also rechecked current Apple primary privacy guidance. No production, test, specification, documentation, packaging, or evidence file was modified.

## Findings

### High — Both shipped privacy manifests contain an invalid empty Required Reason API array

Both target-owned manifests include `NSPrivacyAccessedAPITypes` with an empty array (`SDK/Sources/NearWire/PrivacyInfo.xcprivacy:5-6`; `SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy:5-6`). Apple's current TN3181 identifies an empty `NSPrivacyAccessedAPITypes` array as an invalid accessed-API-types value and explicitly says to remove the key when the array would be empty ([TN3181: Debugging an invalid privacy manifest](https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest)). The current implementation uses no reviewed Required Reason API, so omission—not an empty declaration—is the correct representation.

The existing gates do not detect this. `plutil -lint` reports both files as syntactically valid, while Apple explicitly warns that a plist can pass `plutil` and still contain values App Store Connect rejects. `Scripts/check-sdk-performance-structure.rb:101-113` verifies the collected type, purpose, linkage, and tracking Boolean but does not parse or reject empty accessed-API arrays. Consequently `privacy-packaging-audit.md:26` and `final-validation.md:23-24` overstate manifest validity; the built SwiftPM copies are byte-identical to the invalid sources, and CocoaPods packages those same files.

This is not covered by the deliberate aggregate Xcode App privacy-report deferral. Deferring whole-App aggregation to the maintained Demo and release archives is reasonable, but each SDK manifest must already be semantically valid before those later products consume it.

**Required remediation:** remove `NSPrivacyAccessedAPITypes` from both manifests unless a real covered API and approved reason are added. Also follow Apple's canonical no-tracking form by omitting the unused empty `NSPrivacyTrackingDomains` key while keeping tracking false. Extend the manifest validator and mutation tests to reject empty accessed-API arrays and invalid tracking-key combinations, rebuild both SwiftPM and CocoaPods artifacts, refresh hashes/audits, and rerun privacy packaging gates.

### Medium — Cancellation can leak a created collector's display link and battery-monitoring claim before start commit

After `makeCollector` returns, `performOwnedStart` checks `attempt.isCancelled`, then calls `commitStart` (`NearWirePerformanceMonitor.swift:162-172`). `commitStart` independently rechecks the same cancellation flag and can throw (`NearWirePerformanceMonitor.swift:207-215`). Cancellation of any joined start waiter calls the thread-safe `attempt.cancel()` outside actor isolation (`NearWirePerformanceMonitor.swift:198-203`; `PerformanceRuntime.swift:84-103`), so it can occur between those two synchronous checks even though the monitor actor itself is not reentrant in that interval.

If that interleaving occurs, the catch at `NearWirePerformanceMonitor.swift:173-175` releases only the monitor lease; it does not call `collector.stop()`. The live collector's platform storage creates and registers a `CADisplayLink` and may claim App-global battery monitoring during setup (`PerformancePlatformSession.swift:53-71`). Those resources are invalidated and released only by explicit `Storage.stop()` (`PerformancePlatformSession.swift:108-115`); neither the storage nor battery-claim class has deinitialization cleanup. The result can therefore be a process-lifetime display callback and battery-monitoring claim after every public start caller has received cancellation, violating the no-overlap, teardown, and power bounds.

The existing shared-attempt cancellation test cancels while collector creation is held behind a gate and therefore exercises the earlier post-`await` guard, not cancellation between the final guard and commit (`PerformanceMonitorTests.swift:267-318`). The 1,000-cycle test covers committed runs only.

**Required remediation:** once a collector is acquired, establish one exact ownership transfer so every failure before successful run commit awaits `collector.stop()` before releasing the lease and resolving the attempt. Add a deterministic cancellation seam at the final pre-commit boundary and assert exact collector/display/battery/lease counts for cancellation both before and during ownership transfer. A deinitialization safety net may be useful, but it must not replace deterministic async cleanup on the owning path.

### Medium — Final evidence predates the latest production and test change

The current run worker now captures wall-clock `sampledAt` before collector reads (`PerformanceRuntime.swift:172-184`), and the new ordering test verifies `wallClock` precedes `collector` (`PerformanceMonitorTests.swift:43-66`). However, `final-validation.md:26` says that after canonical run `20260712T091700Z-63876` no production or test source changed, and `final-validation.md:42-46` records a 40-test focused run. The current focused suite contains and executes 41 tests. The canonical `raw/08-swift-package.log` compiled the earlier source/test set and therefore does not substantiate the latest checked task state.

The reviewer reran the current focused suite and observed 41 passing tests in 0.429 seconds, so the ordering change is not presently failing that narrow gate. That diagnostic run does not repair repository evidence and does not replace the iOS compilation/simulator, packaging, symbol, API, and full regression gates required by task 5.2. The statement that only wording changed is now factually incorrect.

**Required remediation:** rerun the proportionate canonical gates against the final source/test/manifests after resolving the findings above, capture exact raw output under a new run ID, update focused/full test counts and artifact hashes, and remove or supersede the stale post-canonical statement before task 5.2 remains checked.

## Verified Boundaries

- The source-authored public Performance surface is limited to configuration, safe error/code, lifecycle state, and actor monitor. SwiftPM/CocoaPods API digests and forbidden-consumer fixtures provide useful evidence that Core, snapshot, collector, clock, lease, and test seams remain unavailable to normal consumers.
- Manual source review found no private API, IOKit, `sysctl`, MetricKit, App lifecycle observer, background request, deprecated screen lookup, direct `mach_absolute_time()`, or `ProcessInfo.systemUptime` use. Source-token checks and SwiftPM/CocoaPods object-symbol checks agree for the two prohibited direct clock APIs. Public `getrusage`, `task_info(TASK_VM_INFO)`, UIKit, QuartzCore, Foundation, and Swift `ContinuousClock` usage matches the documented metric boundary.
- The complete-envelope data categories are otherwise conservative: base installation correlation is declared as linked Device ID, optional snapshots as linked Performance Data, both for App functionality with tracking false. SwiftPM target resources and distinct CocoaPods subspec resource bundles assign ownership correctly, subject to the semantic manifest defect above.
- Fixed performance errors do not forward underlying errors, event content, pairing values, endpoints, or system descriptions.
- Ordinary keep-latest delivery remains bounded. Tests provide exact evidence for one retained event after 10,000 admissions, 9,999 coalescences, no catch-up burst, 10,000 projections, and 1,000 committed start/stop teardown cycles. The cancellation leak above is the uncovered exception to the claimed resource bound.
- English documentation is coherent about metric sources and units, unsupported values, battery ownership, estimated FPS, queue semantics, failure cleanup, optional overhead, and host responsibility. `verify-english.sh` passes; semantic reading found no additional documentation issue beyond stale evidence and manifest-validity claims.
- Deferring the aggregate Xcode App privacy report is explicit and appropriately scoped: the current repository has only `Demo/README.md`, the roadmap assigns creation of the maintained Demo project and aggregate report to `demo-distribution-e2e`, and the active spec, task, Performance guide, and privacy audit preserve Demo/release archives as later whole-product gates. This deferral does not excuse invalid SDK-owned manifests.

## Reviewer Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `./Scripts/verify-english.sh`: **PASS** with the expected human semantic-review note.
- `git diff --check`: **PASS**.
- `ruby Scripts/check-sdk-performance-structure.rb --self-test`: **PASS**, demonstrating the current validator does not reject the invalid empty accessed-API arrays.
- `plutil -lint` for both source manifests: **PASS syntax only**; this does not satisfy Apple's semantic rules.
- Current focused `NearWirePerformanceTests`: **41 passed, 0 failed** in 0.429 seconds; repository evidence still records the preceding 40-test state.

## Verdict

**Implementation approval withheld. Exact unresolved actionable finding count: 3 — 1 High and 2 Medium.**
