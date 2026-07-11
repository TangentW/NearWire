# Post-Implementation Architecture Review - Round 2

## Scope

Re-read the complete current uncommitted change and active OpenSpec proposal, design, capability specifications, and tasks. This round independently verified discovery-to-core authority transfer, attempt-token arming, pre-bind cancellation, callback and relay lifetime, ingress drain quantum and combined accounting, internal/public API boundaries, residual scope, Swift 5 strict concurrency, and the real TLS admission integration test.

## Findings

### P3 - The real TLS test fixture forms a recorder/channel retain cycle

**Severity:** P3 (test-only lifetime leak)

**Confidence:** 10/10

**Evidence:**

- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1344-1347` constructs the Viewer `SecureByteChannel` with an event handler that strongly captures `recorder`.
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1828,1851-1855` makes that same recorder strongly retain the Viewer channel.
- `Core/Sources/NearWireTransport/SecureByteChannel.swift:38-40,55,66` retains its event handler for the channel lifetime, and cancellation at lines 111-123 does not clear that immutable handler.

**Impact:** The integration test leaves the recorder, Viewer channel, expectations, driver, and cancelled `NWConnection` reachable after the test returns. A single run is small, but repeated or stress execution accumulates test-only network objects and can hide future lifetime regressions.

**Actionable remediation:** Capture the recorder weakly in the Viewer channel handler, for example `{ [weak recorder] event in recorder?.receive(event) }`. Alternatively, add an explicit recorder operation that clears `storedViewerChannel` after cancellation. Prefer the weak capture and add a weak-sentinel assertion after cleanup if lifetime behavior is intended to remain part of this integration gate.

## Verified Remediation and Architecture

- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:145-175` completes discovery cleanup, constructs and arms the permanent core with its attempt token, records `.transferred`, and clears admission-owned hello state before channel construction and before the first actor suspension.
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:156-205` installs the attempt token at initialization, starts in `.transferred`, preserves a pre-bind terminal cancellation, and makes both `bind` and `run` reject the stored terminal state. A cancelled unbound core cannot revive or start its channel.
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1059-1092` deterministically pauses after transfer, cancels the unbound core through admission authority, and proves the driver never starts.
- `SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:62-139` accounts pending and in-flight nonterminal callbacks together until batch completion, while `SDKSessionTransportCore.swift:104-105,212-232` limits each actor drain turn to eight items and reschedules through the single-drain gate.
- The permanent core/channel/ingress and admitted-handle relay ownership graph contains no production retain cycle, callback retargeting, or second terminal authority.
- Admission declarations remain internal; no supported SDK API, product, target, dependency, lease claim, facade state mutation, queue drain, incoming publication, effective-rate negotiation, or Event transfer was introduced.

## Validation Notes

- Swift 5 language mode with `-strict-concurrency=complete -warnings-as-errors`: compiled successfully.
- Focused `SDKSessionAdmissionTests`: 27 executed, 0 failures, with the real TLS test skipped only inside the restricted process sandbox.
- Targeted real TLS admission test outside the restricted sandbox: 1 executed, 0 failures.
- `Scripts/check-session-admission-structure.rb`: passed.
- `openspec validate sdk-session-admission --strict`: passed; optional PostHog telemetry could not resolve its network endpoint and did not affect validation.
- `git diff --check`: passed.

No other architecture, API-boundary, production lifetime, ingress-accounting, residual-scope, or Swift 5 concurrency findings were identified in this round.
