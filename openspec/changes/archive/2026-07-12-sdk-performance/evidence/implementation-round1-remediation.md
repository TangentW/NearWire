# Implementation Round 1 Remediation

Date: 2026-07-12

## Setup ownership and cancellation winner

- Starting now owns one exact setup Task through `PerformanceStartAttempt` rather than executing setup in the first public caller.
- Any Starting waiter cancellation, explicit stop, or monitor teardown cancels that shared Task. All callers await the same bounded outcome receipt.
- The setup worker owns lease and collector handles until one atomic commit seal transfers them to the run worker. Every pre-transfer error or cancellation stops the collector before releasing the lease.
- Cancellation now dominates typed and unknown setup errors that arrive after invalidation. A stop that installs Stopping before commit rejects the prepared run and waits for cleanup.
- MainActor display-link creation and battery claims use the attempt's locked acquisition gate, so an acquisition cannot begin after cancellation or commit sealing. The display link remains paused until activation.

Deterministic coverage includes cooperative setup cancellation, waiter cancellation followed by an unknown late error, stop followed by a typed late error, final pre-activation cancellation with exact collector/lease cleanup, and cancelled/sealed acquisition rejection.

## Activation epoch and baselines

- Collector construction only prepares resources. Immediately before commit, activation resets and unpauses the display observer, captures a fresh `ContinuousClock` boundary, primes CPU at that boundary, and returns the same boundary to the run worker.
- A five-second fake setup delay now produces a one-second first header interval and a CPU value calculated only from the post-setup successful pair.
- The 1,000-cycle test now asserts exactly 1,000 activations and 1,000 stops.

## Public API and privacy manifests

- Removed the unapproved public `CustomStringConvertible` conformance and `description` member from `NearWirePerformanceError`.
- Removed empty `NSPrivacyAccessedAPITypes` and `NSPrivacyTrackingDomains` keys from both manifests. The semantic validator and mutation tests now reject those empty-key forms.
- Current source and iOS-built manifest hashes match byte-for-byte and are recorded in `privacy-packaging-audit.md`.

## Affected validation

- Focused Performance suite: 50 passed, 0 failed in 0.420 seconds.
- Complete arm64 iOS 16 source and test compilation: passed with complete concurrency and warnings as errors.
- Privacy semantic mutation tests and `plutil -lint`: passed.
- Strict active-change OpenSpec validation: passed.
- `git diff --check`: passed.

The first canonical raw run is marked historical. A complete new canonical run will replace it after the fresh independent review round reports no unresolved findings.
