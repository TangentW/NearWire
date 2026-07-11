# Post-Implementation Security, Performance, and Documentation Review — Round 3

Reviewed the complete current diff from scratch, including all active-pump specifications and tasks, production and test source, current documentation, validation scripts, evidence artifacts, and prior implementation reviews. The Round 2 report was used only to identify areas requiring fresh inspection. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Findings

### 1. HIGH — The claimed publication-first terminal race still does not race terminal with the in-flight publication

**Evidence**

- The normative scenario requires terminal close and an in-flight Viewer-to-App publication to race at the shared gate. Publication-first must commit the Event before terminal, terminal-first must publish nothing, and the in-flight charge must remain until that ordering resolves (`specs/sdk-active-event-pump/spec.md:263,285-289`). The cancellation scenario also requires stale results from a publication that won before terminal to leave core state unchanged (`specs/sdk-active-event-pump/spec.md:317-321`).
- The new terminal-first test does exercise the correct production path: it suspends before `publishIncomingActive` claims the gate, observes the retained in-flight charge, cancels the handle, releases the publication, and proves no stream output (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:465-538`).
- `testPublicationFirstDefersPolicyAndPublishesExactlyOnce` suspends only after `publishIncomingActive` has returned, proves the Event is visible and policy offers remain deferred, then releases the completion and waits for both policies to commit (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:540-641`). It calls `handle.cancel()` only after the completion has resumed, the in-flight charge has cleared, and both deferred policies have committed (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:632-643`). Terminal never races the in-flight publication, so the test does not exercise terminal-after-gate-claim/before-core-completion or a stale matching publication result.
- The requirement map nevertheless labels that test as publication-first terminal-linearization evidence (`evidence/requirement-to-evidence.md:16,21`), and Task 6.4 remains checked for both terminal-before/after-publication (`tasks.md:30-35`).
- The untested ordering has distinct state transitions: the gate claim publishes on `NearWire`, the injected completion seam can keep `incomingInFlight`, its Task/token, and the captured bucket pending, terminal cleanup invalidates and clears them, and only then does the late result reach `completeIncomingPublication` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1599-1645,1858-1864`). The policy-only suspension does not prove that stale-result path.

**Impact**

The current implementation appears structured to reject the late token, but the security-sensitive committed-before-terminal boundary is still not directly established. A regression that consumes the captured token after terminal, reapplies deferred policy, mutates a cleared bucket, duplicates publication, or mishandles in-flight accounting could pass the test currently cited for the publication-first winner.

**Required remediation**

In the publication-first test, wait until the Event has won the gate and the completion seam is holding the result, then cancel the handle before releasing that seam. Assert exactly one stream Event, exact terminal state and at-most-once channel cancellation, cleared terminal accounting, no policy acceptance or bucket installation after terminal, and no duplicate output or core mutation when the stale completion is finally delivered. Keep policy-deferral/ordered-commit coverage as a separate nonterminal test if needed. Update the requirement map only after the true terminal-after-publication winner is exercised.

### 2. MEDIUM — Focused and packaging evidence combines stale command results with post-run remediation coverage

**Evidence**

- `active-pump-focused.md` records one `NearWireTests` command finished at 02:39:58 with 147 tests, but the next lines attribute 65 `SDKSessionAdmissionTests`, 24 `NearWireBufferTests`, and all Round 2 remediation scenarios to that run (`evidence/active-pump-focused.md:13-19`). Those tests were added later; the current source timestamps are 02:45:04 for `SDKActiveEventPump.swift`, 02:46:33 for `SDKSessionTransportCore.swift`, and 02:55:16 for `SDKSessionAdmissionTests.swift`.
- A fresh independent execution during this review ran the current `swift test --filter NearWireTests` suite and produced 158 passing tests, not the recorded 147. The current focused `SDKSessionAdmissionTests` subset produced 65 passing tests.
- The repository packaging gate is recorded at 02:41:53 (`evidence/validation-gates.md:10-19`), before the Round 2 production and test changes above. It therefore did not validate the current iOS package, Core parity, API sealing, production TLS filter, and boundary checks as one current-diff run.
- The complete strict-concurrency package was rerun at 02:57:19 and records 352 passing tests (`evidence/validation-gates.md:3-8`), which is useful current compilation/regression evidence, but it does not retroactively change the command, count, time, or platform coverage of the stale focused and packaging entries.
- Tasks 7.4 and 7.5 correctly remain unchecked pending exact current validation and evidence capture (`tasks.md:42-43`).

**Impact**

The current focused tests pass, but the evidence artifact is not an exact audit trail: it associates scenarios with a command that could not have executed them and retains packaging results from before the relevant source changes. This weakens release reproducibility and could allow current iOS/package/API-boundary regressions to be hidden behind an earlier green run.

**Required remediation**

Rerun the complete focused and repository packaging commands against one stable current diff. Replace the stale timestamps, counts, durations, and scenario inventory with the exact new outputs; rerun CocoaPods and any other gate whose recorded execution predates the final production change. Keep Tasks 7.4 and 7.5 unchecked until every recorded command is current and internally consistent.

## Verified Controls Without Findings

- Terminal-first downlink publication now uses the actual `publishIncomingActive` path, holds the selected Event charged before gate resolution, and proves no stream output after terminal wins.
- Publication-time policy deferral, deferred-policy overflow, exact combined FIFO/in-flight count and byte pressure, and slow-subscriber isolation have direct focused tests and passed independently during this review.
- Negotiation owner refresh is separately tokenized, bounded to one queue-service quantum and one authorized successor, mutually exclusive with active outbound drain, and cancelled at terminal cleanup. User documentation and the ownership/resource audit now describe that Task and cite its live/unavailable result-order tests.
- Stable transport backpressure remains event-driven without positive-token polling; completed-frame overflow fails closed without continuation chains; incoming accounting uses exact record units; diagnostics remain bounded and saturating.
- Active traffic remains on the admitted TLS 1.3 channel, with no plaintext path, certificate bypass, persistence, secret-bearing diagnostics, supported API expansion, Core/SDK runtime dependency, entitlement, or privacy declaration added.

## Validation Performed During Review

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round3-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round3-swiftpm-cache swift test --filter SDKSessionAdmissionTests`: PASS — 65 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round3-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round3-swiftpm-cache swift test --filter NearWireTests`: PASS — 158 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check`: PASS before this report was added.

## Unresolved Count

**2 unresolved findings: 1 High, 1 Medium.** Security/performance/documentation closure is not granted.
