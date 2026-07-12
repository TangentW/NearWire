## 1. Change Gate

- [x] 1.1 Validate proposal, design, delta specs, and tasks in strict mode before modifying production or test source.
- [x] 1.2 Obtain lightweight independent architecture/API, correctness/testing, and security/performance/documentation pre-implementation reviews; record and resolve actionable findings.

## 2. Public API and Internal Snapshot Construction

- [x] 2.1 Replace the Performance bootstrap marker with only the exact approved public configuration, error, state, and monitor declarations; keep every snapshot, metric, collector, clock, lease, and test seam internal.
- [x] 2.2 Implement strict duration/group configuration validation, content-safe error mapping, unknown battery/thermal mapping, closed metric-key validation, and direct internal construction of the Core V1 schema.
- [x] 2.3 Add a bounded latest-state hub with immediate current yield, exact subscriber termination, no history, and no monitor retention.

## 3. Monitor and Collectors

- [x] 3.1 Implement the total actor-isolated lifecycle transition table, internal Starting and Stopping token/phases, same-attempt start joining, same-cleanup stop joining, start-after-cleanup gating, failure-targeted Stopping with receipt-before-Failed publication, stop override to Stopped, token checks before every setup acquisition/authorization/final commit/cleanup completion, a cancellation-aware activation authorization followed by one locked cancellation-versus-commit winner, exact per-NearWire monitor lease, idempotent running start/stop, exact run generation/token, shared pre-commit cancellation, deinit cancellation, and cleanup that cannot retain the monitor, overlap generations, or release successor resources.
- [x] 3.2 Implement the public-interface process sampler using the specified optional initial and successful-to-successful CPU baseline state machine and current physical footprint, with initial/read/recovery/invalid-pair unavailable outcomes, restart reset, independent memory behavior, and no MainActor work.
- [x] 3.3 Implement the iOS MainActor display/device session with one main-display observing CADisplayLink, exact callback-timestamp FPS formula, stable-unsupported maximum FPS without deprecated/guessed screen lookup, managed/unmanaged best-effort battery policy, thermal/low-power reads, bounded interval counters, and no notification or lifecycle observer.
- [x] 3.4 Implement supported NearWire buffer diagnostics projection with only overflow/expiry/routing terminal removals in the saturated drop count, the closed metric-key inventory and precedence, disabled-group no-work behavior, stable unsupported metrics, actual monotonic interval calculation, and one-sample/no-catch-up scheduling.
- [x] 3.5 Convert each aggregate to the Core schema and submit exactly one ordinary `nearwire.performance.snapshot` using the exact keep-latest key; add no transport, queue, persistence, retry, ACK, or connection side path.
- [x] 3.6 Add the macOS compile path that throws unsupported before monitor lease or collector setup and imports no AppKit.

## 4. Correctness, Resource, and Boundary Tests

- [x] 4.1 Add pure configuration and internal/Core construction tests for all valid boundaries, invalid fields, unknown enums, JSON parity, units, real zero, missing, disabled, temporary, permission-denied, unsupported, exact sorted key inventories, precedence, uniqueness, and safe errors.
- [x] 4.2 Add deterministic fake-clock/collector/NearWire-seam tests for first-after-full-interval behavior, header rounding and clamping, slow collection, delayed wake, restart reset, one sample per wake, no catch-up, CPU baseline recovery, invalid counters and clocks, FPS cadence and invalid timestamps, unavailable-value projection, exact keep-latest type/key, queue admission, drop-counter saturation, submission failure, and the critical cancellation/commit winners.
- [x] 4.3 Add explicitly gated lifecycle tests for same-attempt starts, shared setup cancellation, cancellation after activation authorization, stop during setup, explicit and failure cleanup, stop override before cleanup receipt, restart after cleanup, stale outcomes, second-monitor exclusion, partial-start failure, deinitialization, state subscribers, and noncooperative dependencies. Add exact fake collector/lease teardown assertions over 1,000 cycles and use iOS smoke coverage for real display and battery resources instead of claiming deterministic UIKit resource counters.
- [x] 4.4 Add iOS platform collector smoke tests for CPU/memory/display/device behavior and macOS unsupported behavior without asserting device-specific availability or fragile numeric timing.
- [x] 4.5 Add deterministic 10,000-turn no-sleep benchmark evidence, resource-on/off counts, and queue coalescing stress; report timing separately from hard correctness bounds.
- [x] 4.6 Add focused SwiftPM/CocoaPods Performance consumer smoke fixtures, an SDK-only optional-module fixture, separate base Device ID and optional Performance privacy-resource presence/absence checks, an installation-correlated envelope fixture, and package/subspec framework-isolation checks. Keep behavior and manifest-content assertions in XCTest instead of creating a parallel script-test framework.

## 5. Documentation and Validation

- [x] 5.1 Add English Performance integration/API documentation and update README, distribution, public API, event schema, privacy, and roadmap with lifecycle/reentrancy/cleanup gating, units, sources, initial CPU recovery, unavailable semantics, Device ID and Performance Data ownership/linkage, battery ownership, estimated-FPS/main-display warning, unsupported maximum FPS, platform behavior, failure reporting, queue delivery, and overhead limits.
- [x] 5.2 Run focused Performance tests, full Core/SDK/UI/Performance suites, iOS simulator collector tests, macOS fallback tests, format, English, diff, version, package, podspec, consumer smoke, plist, privacy-resource packaging, and strict OpenSpec gates; save exact commands, results, hashes, and tool versions under `evidence`. Preserve the aggregate Xcode App privacy report as a Demo and release-hardening gate because it requires a real host App archive.
- [x] 5.3 Record requirement-to-evidence, supported public API, snapshot projection parity, retention/resource/continuation/generation overlap, framework/dependency, complete-envelope Device ID and Performance Data ownership/linkage, privacy-manifest/Required-Reason, benchmark, and spec-to-evidence audits.

## 6. Independent Completion Review

- [x] 6.1 Obtain independent architecture/API, correctness/testing, and security/performance/documentation implementation reviews and save each report.
- [x] 6.2 Fix every actionable finding, rerun affected validation, and obtain a fresh zero-finding review round across all three dimensions.
- [x] 6.3 Validate all OpenSpec specs strictly, archive `sdk-performance`, and verify the archived specs and evidence before starting `viewer-application-foundation`.
