# Spec-to-Evidence Audit

| Requirement | Implementation evidence | Validation evidence |
| --- | --- | --- |
| SDK recovery is default-enabled, bounded to 20 attempts, starts at one second, caps at 30 seconds, and retains explicit opt-out | `NearWireReconnectionPolicy.automatic`; `NearWireConfiguration.default` and public initializer default; unchanged intent-wide lifecycle engine | Configuration assertions; `testDefaultConfigurationSchedulesAutomaticRecoveryAfterOneSecond`; existing retry budget/backoff/lifecycle tests; 555-test package suite |
| Default App uplink is 4,096/s while downlink remains 50/s and effective policy stays conservative | `NearWireConfiguration` defaults; existing minimum policy acceptance in `SDKSessionTransportCore` | SDK policy admission tests for Viewer requests above and below the App maximum; package suite |
| SDK business buckets use a 0.25-second burst without changing Core defaults | Explicit `burstDurationSeconds: 0.25` at SDK activation and dynamic replacement | `testPermanentCoreCapturesQuarterSecondBusinessTokenAllowances`; Core token-bucket regressions; package suite |
| SDK offline retention is 10,000 Events/64 MiB with existing single-Event and TTL bounds | `NearWireBufferConfiguration.default` and public initializer defaults | Configuration and queue tests; package Release build; CocoaPods lint |
| Viewer requests 4,096/10 by default and migrates only exact schema-v1 `20/10` | `ViewerRatePolicy.default`; schema version 2 decoder and exact legacy comparison | Legacy-default, customized-global, Bundle-policy, nickname, persisted-version, and reload tests in `ViewerFlowControlTests` |
| Viewer uplink queue is 10,000/64 MiB; downlink remains 5,000/16 MiB | Directional queue constants and distinct `EventQueueLimits` in `ViewerDeviceSession` | Directional-limit assertions, queue integration tests, complete maintained Viewer suite |
| Viewer business buckets use 0.25 seconds while system traffic remains 64/s with burst 128 | Three explicit business bucket constructions; unchanged system bucket construction | Business capacity 1,024 and system capacity 128 assertion; flow-control suite |
| Viewer callback ingress is bounded to 2,048 Events and 64 MiB while retained Session remains 256 MiB | `ViewerLiveProjectionLimits.ingressCount = 2_048`; unchanged byte and retained values | Full minimum-accounted 2,048-capacity test; independent positive-byte capacity test; 100,000-offer stress; Performance freeze regression; maintained Viewer suite |
| Documentation states rate, retry, burst, migration, queue, ingress, and non-lossless semantics truthfully | Updated SDK lifecycle/API/Event pump, Viewer flow-control/memory/Event Explorer, and roadmap documents | Three-role review rounds with all findings resolved and final no-findings review |
| SPM and CocoaPods distribution remain valid | No manifest or podspec topology change; Swift 5/iOS 16 boundaries retained | 555 package tests, Release build, `pod ipc spec`, and `pod lib lint --allow-warnings --skip-tests` all pass |

All specified behaviors have matching implementation and regression evidence. The complete final
review has no unresolved finding. Signing entitlements remain intentionally outside this unsigned
change validation; no signing setting is changed. The unrelated Xcode-host localization scan
limitation is recorded without weakening or modifying that test.

OpenSpec archived the validated change as
`2026-07-18-raise-default-uplink-and-reconnect` and applied all five capability deltas to the main
specifications. Post-archive `openspec validate --all --strict` reports 33 specifications passed and
zero failed.
