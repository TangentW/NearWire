# Post-Implementation Security, Performance, and Documentation Review — Round 2

Reviewed the complete current diff from source, including all active-pump specifications and tasks, production and test source, public documentation, validation scripts, current evidence, and prior review reports. Round 1 remediation claims were treated only as leads and were checked against the current implementation. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Findings

### 1. HIGH — Downlink publication/terminal linearization is still claimed complete without testing either required winner

**Evidence**

- The active-pump specification requires publication-first to commit the stream Event before terminal and terminal-first to publish nothing, while keeping the Event charged until the ordering resolves (`specs/sdk-active-event-pump/spec.md:263,285-289`). It separately requires barrier-capable publication entry/claim seams and deterministic coverage of both operation-gate winners (`specs/sdk-active-event-pump/spec.md:303-305,317-321`).
- Task 6.4 is already checked and explicitly claims barrier-controlled `terminal-before/after-publication`, policy-during-publication, subscriber-isolation, and cleanup tests (`tasks.md:30-35`).
- The requirement map points both publication winners to `NearWireBufferTests.testActiveWireDrainGateHasExactTerminalFirstAndCandidateFirstOutcomes` (`evidence/requirement-to-evidence.md:16,21`). That test drives `drainActiveWire` and proves the App-to-Viewer queue-removal/mailbox gate only (`SDK/Tests/NearWireTests/NearWireBufferTests.swift:472-544`); it never invokes the Viewer-to-App `publishIncomingActive` path.
- The cited downlink test is a normal successful publication followed by cancellation (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:383-434`). The production TLS integration is also a happy-path publication and teardown. Neither holds the in-flight publication before the gate, closes terminal on the opposite side, asserts stream output for both winners, checks the retained in-flight charge while the winner is unresolved, or exercises a deferred policy in that suspension window.
- The actual downlink path has distinct behavior that the outbound test cannot prove: the core removes the FIFO head into `incomingInFlight`, starts a separate publication Task, and only later clears the charge and commits the captured bucket (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1580-1623`); `NearWire.publishIncomingActive` performs a TTL recheck and a separate gate claim around event-hub publication (`SDK/Sources/NearWire/NearWire.swift:833-850`).

**Impact**

The implementation appears to use the intended shared gate, but the security-sensitive cancellation boundary and its memory/accounting lifetime are not established by the recorded evidence. A regression that publishes after terminal, clears the in-flight charge before the gate winner is known, consumes a token on a losing result, or commits a new policy before old-policy publication completes could pass every current cited gate. The requirement map therefore overstates coverage and Task 6.4 is prematurely complete.

**Required remediation**

Add deterministic downlink-specific tests that suspend the selected in-flight publication at publication entry/claim and force both gate winners. For terminal-first, assert no stream output, no token commit, exact terminal cleanup, and at-most-once channel cancellation. For publication-first, assert one complete stream Event before terminal, old-policy token consumption only for the live matching result, and no duplicate output from the stale completion. While each publication is suspended, assert that combined count/byte accounting still includes the in-flight item; add a policy offer in that window and prove its acceptance and both bucket replacements occur only after the old-policy publication completes. Add the subscriber-isolation case required by Task 6.4, correct the requirement map to cite those exact tests, and leave Task 6.4 unchecked until all named evidence exists.

### 2. MEDIUM — The task/timer/power audit omits the negotiation owner-refresh Task introduced by remediation

**Evidence**

- Negotiation signals now create and retain a separately tokenized `ownerRefreshTask`; due maintenance or a relatched signal can schedule one bounded successor, and terminal cleanup cancels and releases it (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:612-650,1836-1838`). This was the correct implementation response to the Round 1 lost-shutdown finding.
- The user documentation nevertheless states that the core owns at most the policy deadline, outbound drain/decision, and incoming publication/decision work (`Documentation/SDK-Active-Event-Pump.md:49-64`). It does not mention the owner-refresh Task or its negotiation-only successor rule.
- The evidence artifact presents its task list as the complete set retained by active ownership but likewise omits owner refresh (`evidence/ownership-resource-audit.md:36-47`). It then says all tasks are covered by the listed token/cancellation audit.
- Task 7.5 specifically requires an exact task/timer/power audit and remains unchecked (`tasks.md:42-43`). The current artifact cannot satisfy that gate as written.

**Impact**

The omitted Task is bounded and cleanup is implemented, so this review found no new polling or retention defect in that path. However, the documentation and evidence undercount live negotiation work and fail to record the condition under which a successor is authorized. That makes the power/resource inventory inaccurate precisely in the path added to close the prior shutdown race.

**Required remediation**

Update both the user-facing bounds section and the ownership/resource evidence to include one negotiation-only owner-refresh Task, its reference-identity token, its mutual exclusion with active outbound drain, its bounded queue-service quantum, the single-successor condition for a relatched signal or remaining due maintenance, and terminal cancellation/release. Link the existing owner-refresh race tests to that audit, then complete Task 7.5 only after the corrected inventory and all other required evidence are present.

## Verified Controls Without Findings

- Stable transport backpressure excludes token availability as a wake while the same candidate remains blocked; capacity progress, selection/policy/owner/terminal change, or TTL drives retry.
- Bounded frame decoding tolerates a partial frame after the exact callback quantum and fails closed only when the same callback completes frame `N + 1`; terminal cleanup drops decoder state without a continuation chain.
- Negotiation owner signals are relatched across an in-flight refresh, blocked outbound completion reaches the deferred-policy commit boundary, and cancellation-first termination observation survives terminal cleanup.
- Incoming records use deterministic per-record retention charges, complete Event wrapper/frame size is used for transport cross-limit validation, expiry consumes the shared publication quantum, and active diagnostics saturate in constant space.
- Active bytes remain on the admitted TLS 1.3 channel; no plaintext path, certificate bypass, persistence, secret-bearing diagnostics, supported SDK API, third-party Core/SDK runtime dependency, entitlement, or privacy declaration was added.

## Validation Performed During Review

- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check`: PASS before this report was added.
- A fresh sandboxed `swift test --filter SDKSessionAdmissionTests` attempt could not compile the package manifest because nested `sandbox-exec` is prohibited in this environment. The current evidence records the same command in an unrestricted validation environment with 55 passing active-session tests, and records 341 passing complete-strict-concurrency package tests; this review does not reinterpret those recorded passes as coverage for the missing scenarios above.

## Unresolved Count

**2 unresolved findings: 1 High, 1 Medium.** Security/performance/documentation closure is not granted.
