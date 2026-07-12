# Implementation Security, Performance, and Documentation Review — Round 2

## Scope

Independently reviewed the current `sdk-performance` implementation, tests, specifications, tasks, Round 1 reports, `evidence/implementation-round1-remediation.md`, public API inventory, both source privacy manifests, validation tooling, current packaging/privacy and final-validation evidence, and the latest 50-test focused tree. The review also rechecked current Apple primary privacy guidance. No production, test, specification, documentation, or packaging file was modified.

## Findings

### Medium — A Starting waiter cancellation can lose after the setup worker seals commit but before Running commits

The active specification requires cancellation by any Starting waiter to cancel the shared attempt, clean partial resources, throw `CancellationError` to every waiter, and preserve the prior public state; caller cancellation before Running commits has the same required outcome (`specs/sdk-performance/spec.md:34-38`). The implementation has a smaller uncovered window that violates that contract.

`PerformanceSetupWorker` activates the collector, performs a cancellation check, seals the attempt, and only then awaits the monitor actor to commit Running (`PerformanceRuntime.swift:211-226`). Once sealed, `PerformanceStartAttempt.cancel()` deliberately stops recording cancellation: it sets `isCancelledValue` only when the attempt is not sealed, although it still cancels the setup Task (`PerformanceRuntime.swift:119-133`). Therefore a waiter cancellation that arrives after `sealForCommit()` but before `commitPreparedStart` executes leaves `attempt.isCancelled == false`. The actor commit guard accepts the attempt, creates the run Task, publishes Running, and resolves success (`NearWirePerformanceMonitor.swift:167-193`). The setup Task's cancelled bit is not checked within that actor commit.

This is not merely a return-value race. The collector has already been activated, including unpausing its display link (`PerformancePlatformSession.swift:89-92`), and successful actor commit transfers the collector and monitor lease to a persistent sampling worker. A caller that cancelled while the monitor was still publicly Starting can consequently start an unintended sampling run and its associated power/resource work.

The new final-precommit test cancels at `beforeSetupCommit`, before activation and sealing (`PerformanceMonitorTests.swift:465-504`), and the sealed-attempt unit test verifies only that later acquisition is rejected (`PerformanceSamplerProjectionTests.swift:97-116`). The latest cancelled-Starting weak-retention test also suspends inside collector construction, before the seal. None exercises cancellation between sealing and actor commit.

**Required remediation:** make cancellation-versus-Running commit one atomic winner decision at the actor commit boundary. For example, retain a cancellation-requested bit even after resource acquisition is closed, and atomically consume/transfer the attempt inside `commitPreparedStart`; cancellation after the transfer may legitimately lose, while cancellation before it must reject commit and drive the existing awaited collector-stop/lease-release path. Add a deterministic post-seal/pre-actor-commit test that asserts all joined callers receive `CancellationError`, Running is never published, the activated collector is stopped exactly once, and display/battery/lease counts return to zero.

### Low — The privacy validator can accept a collected-data record whose tracking value is true

The current manifests themselves are semantically correct: each declares its intended collected-data category with linked true, per-record tracking false, and top-level tracking false; both omit `NSPrivacyAccessedAPITypes` and `NSPrivacyTrackingDomains` (`SDK/Sources/NearWire/PrivacyInfo.xcprivacy:5-21`; `SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy:5-21`). This matches Apple's current guidance: TN3181 says to remove an empty `NSPrivacyAccessedAPITypes` key and permits `NSPrivacyTracking=false` with tracking domains omitted ([TN3181: Debugging an invalid privacy manifest](https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest)); Apple's privacy-manifest documentation defines the collected-data and Required Reason API roles of these keys ([Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)).

The added empty-key mutations are effective, but the semantic validator does not bind Boolean values to their owning keys. It finds the text position of `NSPrivacyCollectedDataTypeTracking` and accepts any later `<false/>` in the document (`Scripts/check-sdk-performance-structure.rb:100-120`). Changing the Performance record's immediate tracking value from false to true still passes that expression because the later top-level `NSPrivacyTracking` value is false. A direct in-memory mutation reproduced this false negative. The self-test includes only empty accessed-API and tracking-domain mutations (`Scripts/check-sdk-performance-structure.rb:183-206`), so it does not protect the declared per-record tracking classification.

The shipped artifacts are not currently wrong, so this is lower severity than the Round 1 manifest defect. It is nevertheless an actionable validation gap because task 4.6 requires mutation self-tests and the privacy audit relies on the validator to preserve tracking-false semantics.

**Required remediation:** parse the plist into key/value pairs and assert the Boolean immediately associated with every collected-data record's `NSPrivacyCollectedDataTypeLinked` and `NSPrivacyCollectedDataTypeTracking` key, plus the top-level `NSPrivacyTracking` Boolean. Add mutations that flip each Boolean independently and require the validator to reject them.

## Verified Remediation and Boundaries

- The Round 1 direct cleanup defect is closed outside the narrower commit-winner race above. The setup worker owns optional lease and collector handles and, on every thrown or rejected pre-transfer path, awaits `collector.stop()` before releasing the lease (`PerformanceRuntime.swift:194-239`). Live platform stop invalidates the display link and releases the battery claim exactly once (`PerformancePlatformSession.swift:128-135`).
- MainActor acquisition is guarded against cancelled or sealed attempts; the display link is created paused and is unpaused only during activation (`PerformancePlatformSession.swift:61-91`). Focused tests now cover cooperative setup cancellation, final pre-activation cancellation, slow cleanup generations, cancelled-Starting retention, 1,000-cycle teardown, and bounded 10,000-turn work.
- The unapproved public `CustomStringConvertible` conformance and `description` member are absent. The public source inventory is limited to the approved configuration, error/code, state, and monitor declarations (`NearWirePerformanceError.swift:3-21`; `Scripts/check-sdk-performance-structure.rb:19-67`).
- Both current source manifests pass `plutil -lint`. The structure validator and its empty-key self-tests pass, and the manifest hashes/audit accurately describe the present sources. The Low finding above concerns future-regression detection, not current manifest contents.
- No new private API, App lifecycle observer, background execution request, unbounded queue/history, direct `mach_absolute_time`, or `systemUptime` use was found. Delivery remains the ordinary keep-latest event path, and the latest focused stress tests remain bounded.
- Documentation remains coherent about metric limits, battery ownership, FPS estimation, optional overhead, queue behavior, and host responsibilities. The aggregate host-App privacy report remains explicitly deferred to the maintained Demo/release archive, which is appropriate for this library-only change.
- Pending canonical recapture is represented honestly. `evidence/final-validation.md:5-28` labels the first run historical and the remediated final recapture pending; tasks 5.2 and 5.3 remain unchecked (`tasks.md:33-34`). `evidence/privacy-packaging-audit.md:26` likewise distinguishes current rebuilt manifest evidence from historical symbol evidence that still needs renewal. No stale evidence is being claimed as canonical for the final tree.

## Reviewer Validation

- `plutil -lint SDK/Sources/NearWire/PrivacyInfo.xcprivacy SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy`: **PASS**.
- `ruby Scripts/check-sdk-performance-structure.rb`: **PASS**.
- `ruby Scripts/check-sdk-performance-structure.rb --self-test`: **PASS**, while the additional per-record tracking-true mutation demonstrably passes the validator's current tracking expression.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Current focused `NearWirePerformanceTests` with complete concurrency and warnings as errors: **50 passed, 0 failed** in 0.425 seconds.

## Verdict

**Implementation approval withheld. Exact unresolved actionable finding count: 2 — 1 Medium and 1 Low.**
