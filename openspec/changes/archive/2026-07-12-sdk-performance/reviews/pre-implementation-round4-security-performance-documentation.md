# Pre-Implementation Security, Performance, and Documentation Review — Round 4

## Scope

Independently reviewed the current `sdk-performance` proposal, design, capability specifications, tasks, Round 1 through Round 3 security/performance/documentation reports and remediation records, existing installation-identity and wire-envelope behavior, root SwiftPM and CocoaPods distribution boundaries, and current Apple primary privacy guidance. This report modifies no production, test, specification, task, evidence, or other review artifact.

## Prior Finding Disposition

### Complete-envelope privacy ownership

The Round 3 finding is resolved. The base NearWire target/subspec now owns a manifest that declares the persistent installation UUID as `NSPrivacyCollectedDataTypeDeviceID`, for App functionality, linked `true`, and tracking `false`. This matches the existing behavior that creates the UUID, persists it in the data-protection Keychain, transmits it in hello, and enables the Viewer to correlate one App installation. The optional Performance target/subspec separately declares `NSPrivacyCollectedDataTypePerformanceData`, for App functionality, linked `true`, and tracking `false`. Performance linkage is assessed over the installation-correlated session rather than only the identifier-free snapshot body.

This split is consistent with Apple's current requirement that a third-party SDK describe the data it collects in its own privacy manifest, its Device ID and Performance Data categories, and its rule that data associated through device or other identifying details is linked unless effective de-identification and re-linkage prevention apply ([privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [describing data use](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests), [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)). No advertising, data-broker, cross-company profiling, or tracking-domain behavior is proposed, so tracking `false` and no tracking domains remain appropriate.

### Packaging and linkage

Manifest ownership is carried through both distributions. SwiftPM processes the base and Performance manifests only in their owning targets. The default NearWire product therefore contributes Device ID disclosure without importing Performance code or its manifest, while `NearWirePerformance` depends on the base product and contributes the additional Performance Data disclosure. CocoaPods likewise requires uniquely named SDK and Performance resource bundles; the SDK subspec is the sole default and the optional Performance subspec depends on it, so the complete Performance integration contains both declarations without resource-name collision or making Performance part of the default install.

This matches Apple's current Swift-package guidance that `PrivacyInfo.xcprivacy` must be explicitly declared as a target resource. The planned SwiftPM/CocoaPods consumers, separate presence/absence checks, plist validation, installation-correlated envelope fixtures, archive inspection, and generated privacy report are proportionate release evidence rather than assumptions about source layout ([adding a privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)).

### Required Reason APIs

The Required Reason contract remains sound. Existing Core/SDK source contains no reviewed covered API requiring a declaration for this change. Performance relative timing is fixed to Swift `ContinuousClock`; direct `mach_absolute_time()` and `ProcessInfo.systemUptime` use is prohibited. The final source, linked/archive symbol, packaged-manifest, and generated-report audits must add every category actually reached by the shipped owning component. This follows Apple's current rule that an SDK must report its own Required Reason API use and cannot rely on the host App or another SDK's manifest ([describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)).

### Battery ownership and resource bounds

The original battery finding remains resolved. Managed mode is explicitly best-effort and coordinates only NearWire claims; an observable external disable is not fought and suppresses battery readings; an indistinguishable external true-over-true write is documented as unsolvable; and a host that owns the App-global switch must select unmanaged mode and maintain it. The planned interleaving and no-mutation tests match those guarantees.

Sampling and retention remain bounded and opt-in: construction starts no work; Starting and Stopping each own one exact task plus only generation-owned partial resources; Running owns one sampling task, at most one display link and one shared managed-battery claim, one monitor lease, bounded baselines/accumulators, and one snapshot at a time; streams retain only one newest value per live caller; and the ordinary NearWire queue retains at most one pending event for the fixed keep-latest key. There is no catch-up burst, retry/history queue, background request, MetricKit subscriber, polling spin, or unbounded callback list. The 10,000-turn timing result remains descriptive while exact work, resource, continuation, generation-overlap, teardown, and queue-coalescing counts are correctness gates.

## New Findings

No new actionable security, performance, privacy, packaging, or documentation finding was identified. Existing documentation still contains the pre-change statement that NearWire packages no privacy manifest, but task 5.1 explicitly requires the privacy, distribution, public API, event, README, and roadmap documentation to be updated for the new base Device ID and optional Performance Data ownership before completion; task 5.2 and the final documentation review remain required gates.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS** (`Change 'sdk-performance' is valid`).
- `./Scripts/verify-english.sh`: **PASS** (`CJK character scan passed. Human review remains required for semantic language compliance.`).
- `git diff --check -- openspec/changes/sdk-performance`: **PASS**.
- Current Apple primary guidance rechecked for SDK manifest ownership, Swift-package resource placement, Device ID, Performance Data, linkage, tracking, and Required Reason APIs.

## Verdict

**Pre-implementation security/performance/documentation approval granted. Unresolved actionable finding count: 0.** All prior findings are remediated in the current artifacts. Approval remains conditioned on completing the specified implementation, packaging, generated privacy report, exact resource evidence, documentation updates, and fresh implementation review gates without weakening them.
