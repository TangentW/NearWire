# Pre-Implementation Security, Performance, and Documentation Review — Round 5

## Scope

Independently re-reviewed the current `sdk-performance` proposal, design, capability specifications, tasks, all prior security/performance/documentation reviews and remediation records, the Round 4 correctness finding and its remediation, existing installation-identity and event-envelope behavior, root SwiftPM/CocoaPods boundaries, and current Apple primary privacy guidance. This report modifies no production, test, specification, task, evidence, or other review artifact.

## Round 4 Remediation Verification

### Failure cleanup is serialized and resource-bounded

The post-start failure gap is resolved. A current-run sampling or submission failure now invalidates its generation and enters the same exact internal Stopping barrier used by explicit stop, with Failed as its pending terminal target. The run worker releases all generation-owned display, battery, monitor-lease, session, baseline, accumulator, and task resources before emitting its exact cleanup receipt. The actor cannot discard the predecessor task handle or publish Failed until that receipt is validated.

This ordering closes the prior resource-overlap window. A start arriving during failure cleanup waits for the exact receipt before beginning or joining a fresh Starting attempt. An explicit stop joins the same cleanup, overrides a pending Failed target with Stopped, and publishes no Failed value if it wins before receipt commit. Stopping admits no successor acquisition; stale receipts and late failures are token-checked; predecessor handles cannot release successor resources; and slow or noncooperative cleanup remains bounded to one cleanup generation rather than permitting duplicate work.

The design, normative scenarios, implementation task, and deterministic tests now agree on receipt-before-publication ordering, stop override, start/stop during slow failure cleanup, cancellation isolation, duplicate or stale completion, exact live-resource counts, no generation overlap, and weak-retention probes. No new security or performance exposure is introduced by retaining the public Running value during the private Stopping interval because lifecycle operations consult the private phase and cannot take the Running no-op path.

## Complete Prior Decision Audit

- **Privacy ownership:** the base NearWire component owns its persistent installation UUID declaration as linked, non-tracking Device ID for App functionality. The optional Performance component separately owns linked, non-tracking Performance Data for App functionality. The complete installation-correlated envelope, rather than only the snapshot body, determines linkage.
- **Packaging:** SwiftPM processes each `PrivacyInfo.xcprivacy` only in its owning target. CocoaPods uses separate uniquely named SDK and Performance privacy resource bundles; the default SDK includes only its Device ID declaration, while optional Performance adds its declaration through its SDK dependency. Plist, packaged-resource, envelope, archive, and generated privacy-report checks remain required.
- **Required Reason APIs:** existing reviewed source adds no covered API for this change. Performance timing remains constrained to Swift `ContinuousClock`; direct `mach_absolute_time()` and `ProcessInfo.systemUptime` calls are forbidden; final source and linked/archive audits must add every category actually reached by the shipped owning component.
- **Battery ownership:** managed mode remains explicitly best-effort and NearWire-only. Observable external disable is not fought, true-over-true external ownership is acknowledged as indistinguishable, and hosts that own the App-global switch must use unmanaged mode.
- **Bounded overhead:** construction starts no work; Starting, Running, and Stopping have exact task and resource bounds; state streams retain one newest value per live caller; the fixed keep-latest queue key retains at most one pending performance event; and there is no catch-up burst, polling spin, hidden queue, persistence, retry history, background request, or MetricKit subscriber. Timing evidence remains descriptive while exact work/resource counts are correctness gates.
- **Documentation:** metric units and sources, unavailable versus zero, estimated-FPS limitations, unsupported GPU/power/temperature/rate fields, failure publication, battery ownership, privacy linkage, packaging, and queue behavior remain explicitly required documentation. The pre-change no-manifest statement must still be removed under task 5.1 and is covered by the final documentation and validation gates.

Apple's current guidance continues to support these decisions: third-party SDKs describe their own collection and Required Reason API use; Device ID and Performance Data are distinct collected-data categories; data associated through a device or other identifying detail is linked absent effective de-identification; and tracking is limited to the defined cross-company advertising, measurement, or data-broker behavior not proposed here ([privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [adding a privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk), [Required Reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)).

## New-Issue Search

Rechecked failure receipt ownership, state-publication order, start/stop races, cancellation, deinitialization, stale generations, resource retention, queue accumulation, content-safe errors, privacy inventory, Required Reason drift, resource placement, optional dependency isolation, and pending documentation updates. No new actionable security, performance, privacy, packaging, or documentation finding was identified.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS** (`Change 'sdk-performance' is valid`).
- `./Scripts/verify-english.sh`: **PASS** (`CJK character scan passed. Human review remains required for semantic language compliance.`).
- `git diff --check -- openspec/changes/sdk-performance`: **PASS**.
- Current Apple primary guidance rechecked for privacy-manifest ownership and placement, Device ID, Performance Data, linkage, tracking, and Required Reason APIs.

## Verdict

**Final pre-implementation security/performance/documentation approval granted. Explicit unresolved actionable finding count: 0.** All prior findings remain remediated, including failure-cleanup serialization. Implementation remains conditioned on completing every specified packaging, privacy-report, exact resource, documentation, validation, and fresh implementation-review gate without weakening it.
