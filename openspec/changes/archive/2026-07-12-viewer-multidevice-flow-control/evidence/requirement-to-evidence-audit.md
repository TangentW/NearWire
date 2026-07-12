# Requirement-to-Evidence Audit

Date: 2026-07-13

| Requirement area | Implementation evidence | Executable or inspection evidence | Result |
| --- | --- | --- | --- |
| Finite independent sessions | `ViewerMultiDeviceSessionManager`, provisional entries, exact cleanup generations | 16-slot, duplicate-route, route-variant, recent-row, shutdown foundation tests | Satisfied |
| Continuous same-core protocol | `ViewerAdmissionConnectionCore`, resumable decoder, one pause token, retained-receipt service deferral | Complete and partial approval suffix tests; later-service/older-continuation ordering test in both orders; Core decoder/channel suites | Satisfied |
| Policy negotiation | `ViewerDeviceSession` pending offer and one absolute service wake | Conservative acceptance, repeat rejection, dynamic coalescing, exact timeout, zero-rate tests | Satisfied |
| Preferences | `ViewerDevicePreferences` bounded versioned state | Precedence, validation, deterministic eviction, oversized/corrupt recovery, nickname tests | Satisfied |
| Bidirectional Event transfer | Per-session queues, exact route/epoch/sequence validation, tentative downlink commit | Bidirectional wire test, mailbox retry tests, exact TTL test, full Core queue suite | Satisfied |
| Rate and work bounds | Independent buckets, 32-record slices, 128-record aggregate service turn, 2 MiB default and 19 MiB hard input cap | Zero-rate, burst continuation, service-order repeat, bootstrap Core/SDK tests, code-bound inspection | Satisfied |
| Drop reporting | Typed saturating local counters, one in-flight and one pending typed summary | Keep-latest summary coalescing and Control-reservation test | Satisfied |
| Safe telemetry and UI | Closed reflection, heap-indexed queue oldest wait, typed drops, latest snapshots | Live-node oldest-wait queue test, sentinel reflection test, root-view composition test, English operator guide | Satisfied |
| Packaging and privacy | Root package/podspec unchanged in ownership; Viewer-only Xcode sources | Complete pre-remediation bootstrap pass; current-tree SwiftPM/Viewer suites; three exact unweakened bootstrap reruns with unrelated non-reproducing timing failures; built privacy-manifest inspection | Satisfied with recorded environment limitation |
| Signing boundary | No signing model changed in this change | Unsigned behavior verified; stable signer and final signed entitlement checks explicitly deferred to goal-level `release-hardening` | Deferred by product-owner decision |

All non-signing requirements have direct implementation and validation evidence. The bootstrap instability is retained as explicit evidence and was not suppressed by changing a gate. Round 4 independent architecture/API, correctness/testing, and security/performance/documentation reviews each report exactly zero unresolved actionable findings. No unresolved implementation finding is accepted by this audit.
