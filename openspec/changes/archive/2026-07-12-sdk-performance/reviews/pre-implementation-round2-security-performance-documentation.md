# Pre-Implementation Security, Performance, and Documentation Review — Round 2

## Scope

Independently re-reviewed `AGENTS.md`, every active `sdk-performance` proposal/design/specification/task/evidence artifact, the prior security report, current Core/SDK event and distribution boundaries, root SwiftPM/CocoaPods manifests, local iPhoneOS SDK headers, and current Apple primary privacy documentation. This report changes no production, test, specification, task, evidence, or other review artifact.

## Prior Finding Disposition

### Privacy manifest and Required Reason APIs

The original finding is substantively remediated. The optional Performance product/subspec now owns a `PrivacyInfo.xcprivacy`; SwiftPM and CocoaPods packaging are specified independently from the resource-free default SDK; performance data, App functionality purpose, and tracking false are explicit; and privacy packaging/report validation is a release gate rather than a permanent policy assumption.

The implementation clock is now fixed to Swift `ContinuousClock`. Direct `mach_absolute_time()` and `ProcessInfo.systemUptime` calls are prohibited, and source, linked/archive symbol, packaged-resource, plist, and generated privacy-report audits must add any Required Reason category actually reached by final code. This is appropriately conservative under Apple's rule that an SDK must declare its own covered API use.

### App-global battery monitoring

The original exact-restoration claim is resolved. Configuration exposes managed and unmanaged modes. Managed mode is explicitly best-effort, coordinates only NearWire claimants, stops fighting an observable external disable, and does not claim to solve indistinguishable external writes. Hosts that own `UIDevice.isBatteryMonitoringEnabled` are required to use unmanaged mode and keep it enabled themselves. Tasks now require initial-state, multi-claim, external-write, and unmanaged no-mutation coverage.

## Finding

### High — The planned `linked = false` performance-data declaration conflicts with NearWire's installation-correlated transport

The manifest is specified to declare `NSPrivacyCollectedDataTypePerformanceData` with `NSPrivacyCollectedDataTypeLinked = false` (`proposal.md:14`; `design.md:197`; `specs/sdk-performance/spec.md:165`; remediation evidence lines 24-26). That conclusion considers the snapshot payload in isolation, but NearWire does not transmit it anonymously.

The existing connection contract loads a device-local installation identifier and explicitly lets the Viewer correlate one App installation (`Documentation/SDK-Public-API.md:58-60`). The wire hello carries the App role and installation identifier (`Documentation/Wire-Protocol.md:73`), and accepted events carry NearWire-owned session metadata with source and target identifiers. Consequently the Viewer can associate each performance snapshot with a persistent App installation even though the snapshot content itself has no identifier.

Apple says data is linked when it is associated with identity through an account, device, or other details, and that collected data is generally linked unless identifiers are stripped and re-linkage is prevented ([App Privacy Details — Data linked to the user](https://developer.apple.com/app-store/app-privacy-details/)). This design intentionally preserves installation correlation, so it does not meet that de-identification description. “Tracking false” remains appropriate because no third-party advertising/data-broker combination is proposed, but tracking and linkage are separate declarations.

**Required remediation:** perform the privacy decision over the complete transmitted envelope and Viewer storage/correlation behavior, not only the Core snapshot body. Unless the actual path removes the installation/session association before collection and prevents re-linkage, declare Performance data as linked. Document that snapshots are correlated to an App installation, update the exact manifest/spec/tasks/audits, and include the generated privacy report plus an envelope-level fixture as evidence. If the team retains `linked = false`, it must provide authoritative, reviewable rationale showing why NearWire's persistent installation correlation does not count as linkage under Apple's definition; the current artifacts provide none.

## Verified Boundaries

- Metric semantics remain conservative: process CPU and footprint are App-process values; display cadence is estimated rather than GPU/render throughput; thermal is categorical; unsupported power/GPU/temperature/byte-rate fields are explicit; real zero remains distinct from unavailable.
- The closed metric-key inventory, unavailable precedence, CPU successful-to-successful baseline, FPS timestamp formula, and terminal drop-counter definition remove the prior ambiguity and support deterministic evidence.
- Sampling remains opt-in and bounded per monitor: one sleeping Task, at most one display link and managed battery claim, newest-one state publication, bounded interval state, one snapshot per wake, no catch-up burst, and ordinary keep-latest queue admission.
- Unknown platform/collector/submission errors remain fixed and content-safe; no pairing value, endpoint, event body, arbitrary system description, or application error is forwarded.
- The public API is narrower: snapshots and metric models remain internal, while supported declarations are limited to configuration, content-safe error/state, and monitor. Core/collector/test seams stay non-public.
- The deterministic 10,000-turn benchmark is correctly treated as work-count/regression evidence, with timing reported rather than used as a universal threshold. Real platform smoke and exact resource counters remain separate gates.
- Current iPhoneOS headers expose the planned Darwin/Mach/UIKit/Foundation/QuartzCore interfaces. Final implementation still must avoid describing header presence as App Store approval and must preserve the device/archive/privacy validation gates.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.
- `./Scripts/verify-english.sh`: **PASS**.
- Current Apple primary privacy documentation rechecked for performance data, Required Reason APIs, tracking, and identity/device linkage.

## Verdict

**Unresolved actionable finding count: 1 High.** Required Reason handling and battery ownership are honestly resolved. Pre-implementation approval remains withheld only until the performance-data linkage declaration reflects the persistent NearWire installation/session correlation, or a defensible authoritative rationale supports `linked = false`.
