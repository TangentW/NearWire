# Pre-implementation Finding Remediation

## Scope

This record resolves the first independent architecture/API, correctness/testing, and security/performance/documentation review findings before any production or test source modification. The active proposal, design, capability deltas, and tasks were updated together and then revalidated in strict mode.

## Architecture and API

- Removed every proposed public snapshot, metric, battery/thermal, unavailable, collector, clock, lease, and test-seam declaration. The supported Performance delta is now limited to configuration, content-safe error, lifecycle state, and the actor monitor.
- Made `currentState` actor-isolated and authoritative. The nonisolated stream hub is only a bounded latest-value publication mechanism.
- Added a total lifecycle transition table for success, idempotence, unsupported platform, lease contention, partial setup failure, pre-commit cancellation, post-start failure, explicit stop, restart, stale completion, and deinitialization.
- Replaced the impossible exact global battery-ownership claim with an explicit managed/unmanaged policy. Managed mode is best-effort and documents the unobservable true-over-true conflict; hosts that own UIKit battery monitoring must select unmanaged mode.
- Added a closed metric-key inventory, group ownership, support class, and total unavailable-reason precedence.

## Correctness and Testing

- Defined `transport.droppedEventCount` as overflow, expiration, and routing terminal removals only, saturated at `Int64.max`. Keep-latest coalescing, explicit clear, and transport-admission rejection are excluded.
- Defined the CPU successful-to-successful baseline state machine, including read failure, recovery, counter regression, non-positive elapsed time, overflow, and non-finite results.
- Defined the exact display timestamp ownership rule and `(count - 1) / (last - first)` formula, including zero/one callback, invalid timestamp, delayed sampling, reset, and independent maximum-FPS behavior.
- Expanded the task plan with deterministic transition, CPU, FPS, drop-counter, battery-interleaving, inventory, precedence, saturation, and mutation tests.

## Security, Privacy, Performance, and Documentation

- Replaced the no-manifest claim with a Performance-only `PrivacyInfo.xcprivacy` requirement. After complete-envelope review, it declares `NSPrivacyCollectedDataTypePerformanceData` for `NSPrivacyCollectedDataTypePurposeAppFunctionality`, linked true, tracking false, and no tracking domains because the Viewer deliberately correlates the session to an App installation identifier.
- Assigned the existing installation UUID to a base-SDK Device ID manifest and the optional measurements to a separate Performance Data manifest. SwiftPM and CocoaPods package each from its owning target/subspec. The validation gate includes an installation-correlated envelope fixture and generated privacy report covering both categories.
- Selected Swift `ContinuousClock` and prohibited direct `mach_absolute_time()` and `ProcessInfo.systemUptime` calls. The release gate audits source, linked/archive symbols, packaged manifests, and the generated privacy report, and adds any Required Reason category actually reached by final code.
- Added the battery ownership limitation and privacy behavior to required integration documentation.

The privacy decision follows current Apple primary documentation:

- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Adding a privacy manifest to an app, SDK, or Swift package](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Collected data types, including performance data](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)
- [Collection purposes, including App functionality](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes)
- [Required Reason API declaration rules](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [System boot-time API category](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

Apple states that privacy manifests describe SDK collection and Required Reason API use, Swift Package resources must declare the manifest explicitly, performance data has a dedicated collected-data category, App functionality is an approved collection purpose, and direct `mach_absolute_time()` or `systemUptime` use belongs to the system boot-time Required Reason category. Policy is treated as release-time input rather than a permanent assumption.

## Fresh Validation

Command:

```text
DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive
```

Result:

```text
Change 'sdk-performance' is valid
```

Command:

```text
./Scripts/verify-english.sh
```

Result:

```text
CJK character scan passed. Human review remains required for semantic language compliance.
```

Command:

```text
git diff --check
```

Result: passed with no output.
