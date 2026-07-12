# Pre-implementation Round 3 Finding Remediation

## Scope

This record resolves the three actionable findings from the third independent pre-implementation review round. No production or test source was modified.

## Lifecycle Cleanup Barrier

- Added an internal Stopping phase with one exact nonthrowing cleanup Task and token.
- Stop installs the barrier before awaiting a Starting attempt or Running run. Concurrent stops join it and return only after cleanup.
- Start during Stopping waits without acquiring resources, checks its own cancellation, and then begins or joins one fresh attempt. Cancellation while waiting only on cleanup does not cancel cleanup or a successor.
- Predecessor handles release only predecessor resources; cleanup completion validates its token; Stopping admits no successor acquisition. Tests cover partial setup, MainActor setup, active sampling, slow/noncooperative cleanup, multiple callers, cancellation, and stale cleanup after restart.

## Initial CPU Baseline

- Initial CPU reading is an individual metric read, not collector-session construction. Its failure does not fail start or other groups.
- The monitor may enter Running with an empty CPU baseline. Repeated failures remain temporarily unavailable. The first valid pair establishes the baseline without emitting; the second valid strictly later pair may emit.
- Post-baseline read failure preserves the pair, invalid arithmetic re-baselines without emitting, and stop/restart clears it. Only collector-session construction can produce `collectorSetupFailed`.

## Complete-envelope Privacy Ownership

- The base NearWire target/subspec now owns a privacy manifest declaring its persistent installation UUID as `NSPrivacyCollectedDataTypeDeviceID`, App functionality, linked true, tracking false.
- The optional Performance target/subspec owns a separate manifest declaring `NSPrivacyCollectedDataTypePerformanceData`, App functionality, linked true, tracking false.
- Both declarations are required because NearWire creates and transmits the installation identifier specifically for Viewer correlation, and performance events travel in that installation-correlated session.
- SwiftPM and CocoaPods package each manifest from its owning component. Default SDK installation includes only Device ID; optional Performance adds Performance Data. Envelope fixtures and the generated privacy report must assert both.
