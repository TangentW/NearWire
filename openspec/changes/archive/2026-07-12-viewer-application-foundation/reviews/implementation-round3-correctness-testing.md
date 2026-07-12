# Implementation Correctness and Testing Review — Round 3

Date: 2026-07-12

## Scope

Independently re-read the current `viewer-application-foundation` proposal, design, capability specifications, tasks, implementation evidence, requirement-to-evidence audit, prior implementation reviews, and Round 2 remediation record. Re-inspected the affected Viewer admission, cleanup, handoff, application-model coalescing, identity, certificate, and test implementations. This review specifically retraced every Round 2 correctness/testing finding through executable behavior and checked the remediated state machines for new races, leaks, or unproved requirements. No production, specification, task, test, documentation, or evidence artifact was modified; this report is the only added file.

## Round 2 Finding Disposition

| Prior correctness/testing finding | Round 3 disposition |
| --- | --- |
| Stop receipt omitted already-cancelling and claim-in-progress cleanup | **Resolved.** Every admitted attempt is registered with `ViewerAdmissionCleanupRegistry` before the potentially blocking claim. Slot release and attempt removal no longer release cleanup ownership. The registry remains nonempty through core cancellation, claim completion, and any direct cancellation of a late-returned unattached channel. `stop()` joins that registry and the handoff owner. Gated tests cover Pause, Reject, timeout, replacement, ordinary stop, and claim-in-progress followed by stop, including timeout-before-gate-release and exact cancellation after release. |
| Timeout-terminal and application-model race coverage was incomplete | **Resolved.** The manual monotonic scheduler and explicit barriers now exercise both winner orders for Reject, Pause, replacement, stop, and channel termination against timeout. Assertions cover exact handoff/cancellation, slot release, pending-state removal, and ineffectual late callbacks. Application-model tests now synchronize on listener events, status observation, or gates rather than wall-clock sleeps. |
| Fixed-profile parsing accepted early GeneralizedTime | **Resolved.** DER time parsing now enforces UTCTime only for 1950–2049 and GeneralizedTime only for 2050–9999. Tests check the exact transition tags, successful boundary parsing, and rejection of GeneralizedTime encodings for 1949 and 2049. |
| Reload did not validate a readable sensitive-key attribute | **Resolved by a deliberate, internally consistent contract correction.** Creation still requests permanent and sensitive P-256 Keychain storage. Reload now uses the exact application tag, key class/type, P-256 size, and actual nonexportability without depending on login-Keychain reference attributes that are not reliably readable. The active specification, design, implementation, and tests agree on that portable validation boundary. |

## Fresh Correctness Audit

No unresolved correctness or testing finding was identified.

The cleanup lifetime is now independent of the live-attempt dictionary. `ViewerAdmissionAttemptCleanup` publishes completion only after claim completion, core cleanup, and every direct late-channel cancellation complete. This closes both the already-cancelling and claim-return-after-stop sequences while preserving exact-once budget release. The stop receipt owns one task that waits for both the cleanup registry and handoff shutdown, so a one-second caller timeout does not abandon eventual cleanup ownership.

Handoff and shutdown now share one serialized owner. Transfer is decided while the admission manager's terminal lock is held; accepted handles enter the owner's active set before transfer succeeds, and shutdown rejects later transfers and waits for each accepted handle's `cancelAndWait()`. Automatic and confirmation paths therefore cannot produce a post-shutdown handoff or leave an accepted core outside the receipt.

Channel callbacks synchronously enter the connection core's private serial queue. The bounded decoder and one-Hello terminal gate complete their work before the callback returns, avoiding an unbounded retained event backlog. The dedicated gated test proves receive-side backpressure while Hello processing is held. Pending UI publication is runtime-scoped, latest-only, limited to one delivery per `MainActor` turn, and synchronously deactivated before stopped state is cleared; delayed old-runtime snapshots cannot revive approval UI after stop or restart.

The deterministic terminal matrix is proportionate to the normative transition table. It combines injected monotonic time with explicit ordering barriers rather than relying on scheduler latency. The remaining XCTest timeouts are bounded failure guards around expectations/semaphores, not delays used to establish application behavior. Production retains the live `Task.sleep` implementation behind the scheduler seam, as required for the real ten-second deadline.

Identity and certificate reinspection found the corrected contract coherent. Keychain reads, exact identity lookups, and deletes use noninteractive authentication contexts; identity lookup is restricted to the metadata-owned certificate and verifies correspondence with the exact owned private key. Certificate parsing enforces the canonical 2049/2050 time boundary. The real login-Keychain lifecycle and injected failure-path tests execute without skips in the Viewer suite.

## Independent Validation

- Viewer app-hosted XCTest: **PASS**. The fresh `xcresult` summary reported exactly 53 passed, 0 failed, 0 skipped, 0 expected failures, and overall result `Passed`.
- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.
- Test-source timing audit: no `Task.sleep`, `Thread.sleep`, or `usleep` is used to order Viewer tests. The only test-side `sleep` symbol is the controllable manual scheduler implementation.

The Xcode run emitted only expected toolchain warnings about the macOS 13 deployment target linking current XCTest support libraries and ad-hoc test signing. They did not affect build or test success and do not indicate a product correctness failure.

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**
