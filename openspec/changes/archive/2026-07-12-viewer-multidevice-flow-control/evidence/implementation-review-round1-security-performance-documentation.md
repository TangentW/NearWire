# Implementation Review Round 1: Security, Performance, and Documentation

## Scope and Verdict

This review inspected the current uncommitted implementation for `viewer-multidevice-flow-control` against its proposal, design, normative capability specification, and task plan. It read the modified Core transport/decoder code, Viewer admission/session/manager/preferences/application/UI code, Xcode project changes, tests, operator documentation, and current evidence directory. It also built the arm64 Viewer, inspected the built privacy manifest, and ran the new focused Viewer flow-control tests. No production or test source was modified; this report is the only added file.

The implementation establishes useful foundations: the generation-bound receive-pause gate is bounded and invalidated by channel generation; the resumable decoder retains ordered work under a byte cap; the manager limits live entries to 16 and recent rows to 64; correlation is explicitly tuple-based and unauthenticated; downlink is connection/epoch-bound; UI snapshots are coalesced; diagnostics generally discard underlying errors; documentation correctly describes memory-only Event behavior; and the built app contains the existing linked Device ID plus UserDefaults privacy declarations.

However, four medium-severity implementation/verification defects and one low-severity verification defect remain. The most important is an unbounded sequence of admitted drop summaries that can consume reserved Control progress.

**Exact unresolved actionable finding count: 5 — 0 High, 4 Medium, and 1 Low.**

**Approval withheld.** Fix all findings, add the required deterministic abuse/lifecycle/privacy coverage, save exact validation evidence, and obtain a fresh implementation review round before completing tasks 6.1 or 6.2.

## Findings

### NW-MFC-IMPL-SPD-002 — Medium — Repeated drop summaries can fill the mailbox and consume Control reservation

**Evidence**

- Every local drop calls `flushLocalDropSummary` (`ViewerMultiDeviceSession.swift:795-825`).
- A summary is admitted with no reserved count or bytes, and `pendingLocalDropSummary` is reset immediately after mailbox admission rather than after send completion (`ViewerMultiDeviceSession.swift:805-824`).
- Further drops can therefore admit additional unsent summaries while the previous summary remains in the bounded channel mailbox. Under a slow/non-reading peer this repeats until mailbox capacity is exhausted.
- Business Event batches correctly reserve one Control slot and 64 KiB (`ViewerMultiDeviceSession.swift:700-711`), but Event-lane summaries bypass that protection. The design permits one coalesced pending local summary and requires system telemetry to remain mailbox/coalescing bounded without preventing policy or terminal progress (`design.md:109,125`; `spec.md:198,285-297`).

**Impact**

Queue overflow/expiry or keep-latest churn can convert one bounded counter into many retained wire frames. These frames can consume the slot/byte capacity reserved for policy Control, causing an otherwise healthy session to fail negotiation updates or lose bounded Control progress. The memory ceiling remains finite, but the priority and coalescing security contract is broken.

**Required remediation**

Track at most one admitted/in-flight drop summary plus one coalesced pending aggregate, or introduce typed mailbox ownership/completion sufficient to know when the admitted summary is released. Summary admission must preserve the Control reservation. Add slow-peer tests that generate more losses than mailbox capacity and assert bounded summary ownership, saturating aggregation, one Control admission, and cleanup.

### NW-MFC-IMPL-SPD-003 — Medium — The uplink pump invokes an unconstrained consumer inline on the protocol executor

**Evidence**

- `serviceSession` executes on the connection core's serial executor and calls `deliverUplink` in that turn (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:561-577`).
- `deliverUplink` invokes the arbitrary `uplinkSink` closure synchronously for every drained Event (`ViewerMultiDeviceSession.swift:508-531`). The API provides no nonblocking acknowledgement, execution isolation, or bounded handoff, despite the required nonblocking sink boundary (`design.md:101`; `spec.md:142-146`).
- The implementation now has one replaceable service wake for uplink token and TTL deadlines, which resolves the originally observed wakeup gap, but it does not isolate consumer execution (`ViewerMultiDeviceSession.swift:533-650`).

**Impact**

A slow or reentrant sink blocks the session's decoder, receive-credit resolution, policy work, and terminal cleanup. A shared sink implementation can also couple otherwise independent device sessions. Because the peer controls when legal Events reach this callback, it can amplify application-defined work on the protocol executor.

**Required remediation**

Replace the inline sink with a bounded nonblocking ownership handoff and define overflow, cancellation, and terminal cleanup. Preserve the current coalesced service wake. Test a blocked and reentrant sink, handoff saturation, shutdown, and proof that protocol receive, Control progress, and another session continue independently.

### NW-MFC-IMPL-SPD-004 — Medium — Preference loading decodes unbounded local data before applying record limits

**Evidence**

- The persisted format is intended to contain no more than 256 Bundle policies and 256 route nicknames (`Viewer/NearWireViewer/Session/ViewerDevicePreferences.swift:40-49`).
- `load` fetches an arbitrary `Data` blob and runs `JSONDecoder().decode(StoredState.self, from:)` before checking dictionary counts, key lengths, nickname limits, or a total encoded-byte limit (`ViewerDevicePreferences.swift:162-171`).
- Filtering and deterministic eviction occur only after the complete dictionaries and strings have already been decoded into memory (`ViewerDevicePreferences.swift:124-142`).
- Documentation currently says corrupt state recovers safely and that preference state is bounded (`Documentation/Viewer-MultiDevice-Flow-Control.md:43-49`).

**Impact**

A corrupted, manually modified, or unexpectedly large UserDefaults value can force large JSON allocation and CPU work during Viewer startup. Post-decode eviction does not make the persistence boundary resource-bounded and can make the app fail to start or become unresponsive before listener preparation.

**Required remediation**

Impose a conservative maximum stored byte length before decoding and reject/reset oversized data. Prefer a format that bounds collection counts during decode, or validate a bounded top-level representation before constructing dictionaries. Add tests for oversized raw data, over-count dictionaries, oversized keys/strings, impossible timestamps, unknown schema, deterministic repair, and bounded rewritten state.

### NW-MFC-IMPL-SPD-005 — Medium — Required implementation and packaging evidence is incomplete, and the focused Viewer test fails

**Evidence**

- Tasks 2.1 through 5.5 remain unchecked, including malicious ingress, mixed lifecycle capacity, timeout/partial races, system storms, diagnostics, documentation, affected Core/SDK suites, built privacy inspection, and saved exact evidence (`openspec/changes/viewer-multidevice-flow-control/tasks.md:8-30`).
- The evidence directory contains review reports but no consolidated implementation build/test/package/privacy result artifact.
- `ViewerFlowControlTests.swift` contains six tests (`ViewerFlowControlTests.swift:9-305`) and omits most of the deterministic scenarios required by tasks 5.1-5.4, including the defects above.
- Focused arm64 command:

  ```text
  xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-impl-review-spd-flow-final CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests
  ```

  built successfully but exited 65. Five of six tests passed; `testBidirectionalEventExchangeUsesNegotiatedEpochAndRoutes` failed at line 288 because the downlink wake ended with session state `recent`, queue count zero, and terminal category `localAdmissionFailure` (`ViewerFlowControlTests.swift:275-300`).
- A full unsigned Viewer run also exited 65 on the existing entitlement test, which is expected to require the appropriate packaging/signing setup rather than being treated as passing evidence.
- A built arm64 app was available and its `PrivacyInfo.xcprivacy` did contain UserDefaults reason `CA92.1`, linked Device ID for App functionality, tracking false, and no tracking domains. The documentation rationale is present (`Documentation/Viewer-MultiDevice-Flow-Control.md:43-49`), but exact task-5.5 evidence has not been recorded.
- A direct SwiftPM Core test attempt was blocked by this environment's nested `sandbox-exec`/module-cache permissions; it did not produce a Core pass or product failure.

**Impact**

The implementation cannot be approved from a narrow, currently failing smoke suite. Critical abuse and cleanup paths have no executable oracle, and the repository workflow has no saved proof for affected Core/SDK regression, package structure, privacy resource, or documentation gates.

**Required remediation**

Fix the focused Event exchange failure; implement every proportional test named in tasks 5.1-5.4; run the exact supported repository bootstrap, Core/SDK, Viewer, packaging, structure, format/language, OpenSpec, and privacy-manifest gates; record commands, environment limitations, and exact outputs under this change's `evidence` directory; then mark each checkbox only after its stated evidence exists.

### NW-MFC-IMPL-SPD-006 — Low — Closed diagnostics and reflection are asserted by prose but not enforced by tests

**Evidence**

- New session state includes route installation/Bundle identifiers, nicknames, requested/effective rates, queue values, epochs, and counters (`ViewerDevicePreferences.swift:19-31`; `ViewerMultiDeviceSession.swift:24-49,67-115`). Swift's synthesized reflection can expose stored fields unless callers are constrained or types provide safe reflection behavior.
- Production catches generally map failures to closed terminal categories, which is good, and no new explicit logger was found. However, the required description/debug-description/reflection/presentation tests do not exist (`tasks.md:29`; `ViewerFlowControlTests.swift:9-305`).
- Documentation promises content-free diagnostics and memory-only Event handling, but only the persistence/privacy prose is currently implemented as evidence (`Documentation/Viewer-MultiDevice-Flow-Control.md:43-49`).

**Impact**

A later debug interpolation, assertion, telemetry adapter, or reflection-based test/tool can expose identifiers, rate/queue state, or raw model internals without immediately failing CI. No current production log leak was found, so this is a missing guard rather than a confirmed runtime disclosure.

**Required remediation**

Add deterministic tests over every new error/terminal/description/debug/reflection/presentation surface using sentinel peer IDs, Bundle IDs, nicknames, rates, queue values, Event type/content, metadata, queue keys, epoch, endpoint/TLS data, raw bytes, and underlying errors. Where reflection is an intended surface, expose only closed codes or adopt safe custom reflection; otherwise document and mechanically prohibit reflective diagnostic use.

## Verified Strengths

- `SecureReceivePauseGate` permits one claim per synchronous delivery, suppresses eager rearm while paused, resolves idempotently, invalidates on channel generation change, and has focused immediate/terminal Core tests (`Core/Sources/NearWireTransport/SecureByteChannel.swift:181-197,263-334,397-409,414-500`).
- `WireFrameDecoder.consumeResumable` preserves wire order, distinguishes complete pause/partial/drained progress, rejects retained-byte overflow terminally, and has focused decoder coverage (`Core/Sources/NearWireTransport/WireFrame.swift:65-269`).
- Recorded-timeout partial/drained progress now returns `terminalWithoutResume`; the connection core begins cancellation and returns before applying ordinary decoder progress, so the previously observed receive-rearm defect is resolved in the current tree (`Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift:244-258`; `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:572-584`).
- One replaceable generation-checked service wake now covers queue expiration and uplink token availability without a recurring idle timer (`ViewerMultiDeviceSession.swift:533-650`).
- Session manager dictionaries bound owned sessions to 16 and recent rows to 64, keep exact-route duplicates from replacing live owners, retain disconnecting slots through cleanup, use one expiry wake, and clear recent state on shutdown (`ViewerMultiDeviceSessionManager.swift:24-40,63-157,247-379`).
- UI and documentation repeatedly label identity as unauthenticated. Same-installation different/missing Bundle variants remain separate routes, and connection-bound downlink uses the exact target session (`ViewerRootView.swift:36-43,173-193`; `ViewerMultiDeviceSessionManager.swift:63-133,201-210`).
- Event content is not added to Viewer UI, recent rows, logging, analytics, clipboard, or export. Persistent state is limited to requested policy and nicknames.
- The arm64 build packaged the existing privacy manifest with linked Device ID/App functionality, tracking disabled, and UserDefaults reason `CA92.1`; no new entitlement or third-party runtime dependency was added.

## Required Review Gate

Resolve `NW-MFC-IMPL-SPD-002` through `NW-MFC-IMPL-SPD-006`, rerun affected validation, save exact implementation evidence, and request a fresh independent security/performance/documentation review. Do not mark this implementation dimension complete while any finding or required evidence remains unresolved.
