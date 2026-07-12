# Pre-Implementation Security, Performance, and Documentation Review

## Scope

Reviewed `AGENTS.md`, the active `sdk-performance` proposal, design, delta specifications, tasks, existing Core V1 schema, NearWire built-in event/diagnostics boundaries, root distribution contracts, and the current iPhoneOS SDK headers. This is a lightweight pre-implementation review; no production, test, specification, or task artifact was modified.

## Findings

### 1. High — The unconditional “no privacy declaration” claim is not supportable for an SDK that transmits performance diagnostics

The proposal, impact statement, distribution requirement, and tasks require no privacy declaration or resource. However, the module explicitly collects CPU, memory footprint, display cadence, battery, thermal, power-mode, and queue diagnostics and sends them off-device to a Mac. Apple defines a privacy-manifest collected-data category specifically for performance data and says apps or third-party SDKs that collect data or enable collection should describe it in `PrivacyInfo.xcprivacy` ([Apple privacy manifest guidance](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [performance-data category](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)).

The clock implementation is also unspecified. If implementation directly uses `mach_absolute_time()` or `ProcessInfo.systemUptime`, Apple classifies that as a required-reason API; a third-party SDK cannot rely on the host App's manifest, and elapsed-time reason `35F9.1` has explicit off-device constraints ([required-reason guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [system-boot-time category](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)).

**Required resolution:** replace the unconditional no-manifest guarantee with an explicit privacy decision before implementation. Identify the exact monotonic clock and every API reached by Performance source; determine whether this repository is treated as first-party App code or an independently distributed SDK; and record the collected-data purpose/linking/tracking decision. Conservatively, add a Performance-only privacy manifest declaring performance/diagnostic collection for App functionality, tracking false, and any required-reason category actually used. Ensure SwiftPM and CocoaPods Performance package that resource while the default SDK remains resource-free. If the team concludes no manifest is required, the change must instead include authoritative policy rationale plus an archive privacy-report/API-symbol audit proving that conclusion; it must not rely only on source-token scanning.

### 2. Medium — Exact restoration of global battery monitoring cannot be guaranteed against non-NearWire owners

`UIDevice.current.isBatteryMonitoringEnabled` is one process-global Boolean. The design's reference-counted lease coordinates NearWire monitors, but it cannot observe ownership by host code or another library. If the first NearWire claimant observes `false`, enables monitoring, and unrelated code later decides it needs `true`, restoring the originally observed `false` when the final NearWire lease ends silently disables the unrelated owner's requirement. The reverse order and mid-run external writes are similarly ambiguous because the API has no owner token or compare-and-swap operation. Tests involving only NearWire leases cannot prove the stated global restoration guarantee.

**Required resolution:** narrow the contract from exact restoration to a documented best-effort policy that does not claim ownership of external changes, or require the host to coordinate battery monitoring explicitly. Define behavior when the Boolean changes while a lease is active and test that exact policy with injected external-write interleavings. A conservative implementation may restore only when state still matches the value NearWire imposed, but documentation must acknowledge that the indistinguishable “another owner also wants true” case cannot be solved automatically. Do not describe this as exact global ownership.

## Verified Boundaries

- The current iPhoneOS SDK exposes `getrusage(RUSAGE_SELF)`, `TASK_VM_INFO`/`phys_footprint`, `mach_task_self`, `UIDevice` battery monitoring, `ProcessInfo` thermal/low-power state, `CADisplayLink`, and `UIScreen.maximumFramesPerSecond` in public SDK headers. Implementation review still needs device compilation/smoke evidence and must not describe SDK-header presence as an App Store approval guarantee.
- Metric naming is conservative: process CPU may exceed 100; memory is current process footprint; display cadence is estimated FPS, not rendered throughput or GPU utilization; thermal is categorical; unavailable is distinct from measured zero.
- Unknown/system errors are planned to map to fixed content-safe errors without pairing, endpoint, event, or framework-description leakage.
- Sampling and retention are bounded per explicit monitor: one sleeping Task, one display link, newest-one state streams, interval counters, one snapshot, and ordinary queue keep-latest admission. The no-catch-up rule prevents delayed sampling bursts.
- The 10,000-turn deterministic benchmark is appropriately treated as work-count and regression evidence rather than a universal timing threshold. Real collector overhead remains covered by resource counters and iOS smoke evidence rather than the synthetic timing alone.
- Core/default-SDK dependency isolation, macOS unsupported behavior, no private metric fabrication, and SwiftPM/CocoaPods public-boundary plans are proportionate.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: passed.
- `git diff --check`: passed in the pre-implementation evidence.
- Current iPhoneOS SDK header inspection confirmed the planned Darwin/Mach/UIKit/Foundation/QuartzCore symbols and documented battery sentinel/platform availability.

## Verdict

**Changes required before implementation: 2 actionable findings — one High and one Medium.** Resolve privacy-manifest/required-reason ownership and narrow the impossible exact battery-restoration guarantee. The remaining security, performance, dependency, unavailable-semantics, and evidence plan is suitable for implementation after those corrections and a fresh lightweight review.
