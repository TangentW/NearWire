# Requirement-to-Evidence Matrix

| Requirement area | Primary implementation | Automated evidence |
| --- | --- | --- |
| Exact default-disabled recovery policy | `NearWirePublicModels.swift`, `NearWireConversions.swift` | `NearWireConfigurationTests` boundary, exact-field, nanosecond, cap, and default tests; public consumer compile |
| Pending/active intent ownership | `NearWire.swift`, `SDKConnectionLifecycle.swift` | initial identity suspension, cancellation-stage, connected promotion, disconnect clearing, and lifecycle snapshot tests |
| Explicit-connect precedence | `NearWire.performPublicConnect`, exact spontaneous cleanup marker | invalid-before-lease, suspended-before-validation, active/attempt overlap, recovery-delay cleanup, manual cleanup, spontaneous held-release cleanup, intent-exists, and process contention tests |
| Shared cleanup receipt | `SDKCleanupReceipt`, disconnect/suspend methods | held release, concurrent/cancelled disconnect caller, stale delivery, real process-lease, and fail-closed terminal-wait tests |
| Host-controlled suspension/resumption | `suspendConnection`, `resumeConnection` | no-observer source audit; initial suspension, connected suspension/fresh resume, resume-before-cleanup barriers, disconnect-then-suspend, suspend-then-disconnect, held delay, and inert connected resume tests |
| Phase-aware recovery classification | `SDKLifecycleRecoveryMapping`, `SDKLifecycleRecoveryFailure` | exhaustive all-code/two-phase wrapper test, direct and gate-terminal production routing, and a maximum-two production campaign proving pre-active transport failure stops recovery |
| Latest coherent status | `ConnectionStatusStreamHub`, `NearWireConnectionStatus` | current/late/terminal subscriber, concurrent finish, duplicate bounded stream, and lifecycle status assertions |
| Intent-wide total budget | `scheduleRecovery`, `runScheduledRecovery` | two-attempt capped delay and three-route flapping-success exhaustion test |
| Fresh route and release-before-claim | shared connection pipeline plus coordinator cleanup-start/delivery callbacks | claims/releases across two and three session controllers; exact spontaneous cleanup preflight; release barrier; fresh driver/session/epoch construction |
| No ambiguous replay | existing queue admission plus lifecycle replacement | accepted Event removed on first route and absent from second driver; existing route-affinity tests cover old-session reply drop |
| Distribution and dependency boundaries | root Package/podspec globs and public models | SwiftPM/iOS and CocoaPods consumer/API parity gates, forbidden implementation fixtures, no third-party dependencies |
