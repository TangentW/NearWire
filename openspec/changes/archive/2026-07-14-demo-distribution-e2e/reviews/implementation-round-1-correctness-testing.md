# Implementation Round 1 Correctness and Testing Review

## Verdict

Approved. No material correctness or testing finding remains in this review dimension.

Unresolved finding count: **0**.

## Findings

None.

## Confirmed Correctness and Test Properties

- `Demo/NearWireDemo/Application/DemoModels.swift:38-55` measures and truncates text by UTF-8
  bytes without splitting a Swift `Character`. `Demo/NearWireDemoTests/DemoLogicTests.swift:6-10`
  exercises 512-byte acceptance, 513-byte rejection, and a multibyte truncation case.
- `Demo/NearWireDemo/Application/DemoModels.swift:84-98` keeps only the newest 50 summaries.
  `Demo/NearWireDemoTests/DemoLogicTests.swift:31-66` covers the 49, 50, and 51 item transitions
  and verifies retained order.
- `Demo/NearWireDemo/Application/DemoApplicationModel.swift:167-192` maps the public Event
  direction, decodes the banner payload, applies the exact type/direction/size decision, and ignores
  malformed or ineligible controls. `DemoDriver.reply` at
  `Demo/NearWireDemo/Application/DemoDriver.swift:46-56` replies against the exact captured
  `NearWireEvent`, preserving the SDK's hidden instance and session route affinity.
- The focused production evidence in
  `openspec/changes/demo-distribution-e2e/evidence/validation-5.3-production-regressions.md:11-19`
  covers causal metadata, stale-route rejection, production TLS bidirectional exchange, and Viewer
  route handling. The Demo does not introduce a second transport or weaken those tests.
- `Demo/NearWireDemo/Application/DemoApplicationModel.swift:37-40` starts the two observation
  loops only when absent. Reset at lines 89-108 invalidates the generation, cancels and joins both
  predecessors, stops Performance, awaits disconnect, clears state, and installs fresh observers.
  Teardown at lines 110-124 performs joined observer cleanup, monitor stop, disconnect, and terminal
  shutdown in order. The event loop checks both cancellation and generation before handling and
  replying.
- Performance remains explicit. `DemoApplicationModel.swift:74-87` delegates Start and Stop to the
  one injected monitor, exposes only the public safe Performance error message, and the state observer
  at lines 155-165 and 214-225 presents the monitor's bounded latest state.
- The launch test at `Demo/NearWireDemoUITests/NearWireDemoUITests.swift:5-16` launches the real
  SwiftPM application and checks the injected connection field, initial disconnected state, Event
  action, Performance action, and stopped state. Recorded Simulator evidence reports one passing UI
  test and a stable interactive launch.
- `Demo/NearWireDemo.xcodeproj/project.pbxproj:185-186` assigns the same five production Swift files
  to both application targets, and lines 178-179 assign the same asset catalog. The recorded
  CocoaPods build and source/resource hashes in
  `openspec/changes/demo-distribution-e2e/evidence/validation-6.2-cocoapods-parity.md:7-27`
  support the parity claim.
- Three compact Demo logic tests plus one launch test are proportionate for this maintained reference
  application. They cover Demo-owned mapping and bounds, while the existing SDK and Viewer suites
  retain authority for queues, lifecycle internals, concurrency, TLS, transport, and causal routing.

## Checks Run

- Read the complete active proposal, design, capability deltas, task plan, artifact reviews, evidence,
  Demo production source, unit/UI tests, Xcode project and schemes, Podfile, workspace, changed
  validation scripts, and current tracked and untracked diff.
- `env DO_NOT_TRACK=1 openspec validate demo-distribution-e2e --strict --no-interactive`: passed.
- `swift format lint --strict --recursive Demo`: passed with no findings.
- `ruby Scripts/check-swift-boundaries.rb`: passed.
- `bash Scripts/verify-structure.sh`: passed.
- `bash Scripts/verify-version.sh`: passed for `0.1.0`.
- `git diff --check`: passed.
- Audited the saved results for the current Demo tests: 3 unit tests passed, 1 UI launch test passed,
  and 0 failed or skipped.
- Audited the saved focused production results: SDK causal-reply and route-affinity checks, public TLS
  bidirectional connection, and Viewer bidirectional routing all passed without final skips.
- Audited both SwiftPM and CocoaPods build/product evidence, including identical source membership,
  public call sites, host declarations, and privacy resources.

The reviewer modified no production or test source. This report is the only review write.
