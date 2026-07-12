# Pre-Implementation Security, Performance, and Documentation Review — Round 3

## Scope

Independently reviewed all current `sdk-performance` proposal/design/specification/task/evidence artifacts, both prior security reviews and remediation records, the complete NearWire envelope and installation-identity documentation, root distribution boundaries, and current Apple primary privacy guidance. This report modifies no production, test, specification, task, evidence, or other review artifact.

## Prior Finding Disposition

- **Performance-data linkage is corrected.** The manifest now declares performance data as linked, tracking false, and App functionality purpose. Proposal, design, capability spec, tasks, documentation plan, envelope fixture, generated privacy report, and remediation evidence all assess linkage over the installation-correlated session rather than the identifier-free snapshot body.
- **Required Reason handling remains sound.** The implementation is constrained to Swift `ContinuousClock`, direct `mach_absolute_time()` and `ProcessInfo.systemUptime` calls are prohibited, and final source/archive symbols, packaged artifacts, plist, and generated privacy report must add any category actually reached by the shipped code.
- **Battery ownership remains honest.** Managed mode is best-effort and NearWire-only; observable external disable is not fought; indistinguishable writes are documented; and a host that owns the App-global switch must select unmanaged mode. Tests cover the stated interleavings rather than claiming impossible global isolation.
- **Resource bounds are now internally consistent.** Starting, Running, and caller-owned state continuations are counted separately; setup/run generations are exact; no catch-up loop, history, retry queue, or unbounded collector callback list is planned; and benchmark timing remains secondary to exact work/resource counts.

## Finding

### High — The complete-envelope manifest inventory omits the persistent installation identifier as collected Device ID data

The Round 2 correction appropriately uses the persistent App installation identifier to justify `NSPrivacyCollectedDataTypePerformanceData` with `Linked = true`. However, the planned manifest still declares only Performance Data (`design.md:204`; `specs/sdk-performance/spec.md:181`; remediation evidence). It does not declare the installation identifier itself as a collected data type, and it simultaneously requires the default NearWire SDK to remain privacy-resource-free.

NearWire creates/loads a canonical random UUID from the data-protection Keychain, never resets it, sends it in the hello envelope, and explicitly lets the Viewer correlate one App installation (`Documentation/SDK-Public-API.md:58-60`; `Documentation/Wire-Protocol.md:73`). Apple lists “Device ID” as including an advertising identifier **or other device-level ID**, and privacy linkage is assessed through account, device, or other identifying details ([Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/), [collected data types](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)). The installation UUID is transmitted and retained precisely as a persistent installation-level correlation identifier; marking performance as linked does not itself disclose collection of that identifier.

This is not merely a snapshot-body issue. The optional Performance product depends on and uses the base connection path, while the same identifier is also collected when Performance is absent. A valid ownership decision is therefore required for both artifacts.

**Required remediation:** inventory the complete NearWire data path and assign manifest responsibility for the installation identifier. Unless an authoritative review concludes the persistent identifier is not Apple's Device ID category, declare Device ID as linked, tracking false, with the accurate purpose. Prefer a base-SDK privacy manifest for the base connection behavior and let the optional Performance manifest add Performance Data; update the “default SDK resource-free” contract accordingly. If this repository is treated strictly as first-party source whose host App manifest owns base-SDK collection, state and justify that model explicitly, verify it against Apple's SDK/app packaging rules, and ensure the Performance artifact/privacy report does not imply that Performance Data is the only collected category. Add a manifest/envelope fixture that asserts both the identifier category and performance linkage.

## Verified Boundaries

- Public/private Apple metric claims remain conservative and implementation review has explicit device/archive gates.
- Process CPU, physical footprint, estimated display cadence, categorical thermal state, battery sentinel behavior, and unsupported GPU/power/temperature/rate semantics are accurately distinguished.
- Content-safe errors exclude underlying system descriptions, event content, pairing data, endpoint data, and arbitrary App errors.
- Lifecycle reentrancy, subscriber bounds, CPU/FPS baselines, drop-counter semantics, unavailable precedence, queue keep-latest behavior, and the 10,000-turn work-count benchmark have proportionate deterministic evidence plans.
- SwiftPM/CocoaPods optionality, internal Core/collector isolation, macOS unsupported behavior, and no third-party runtime dependency remain appropriately specified, subject to the privacy-resource ownership correction above.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.
- `./Scripts/verify-english.sh`: **PASS**.
- Current Apple primary guidance rechecked for Performance Data, Device ID, identity linkage, tracking, Required Reason APIs, and privacy-manifest ownership.

## Verdict

**Unresolved actionable finding count: 1 High.** Performance linkage, Required Reason handling, battery ownership, and resource bounds are otherwise approved. Pre-implementation approval remains withheld until the persistent installation identifier has an explicit, defensible collected-data category and manifest owner across the base and optional Performance artifacts.
