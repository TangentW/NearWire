# Pre-implementation Round 2 Finding Remediation

## Scope

This record resolves all five actionable findings from the second independent pre-implementation review round. No production or test source was modified.

## Architecture and API

- Added an internal Starting phase and exact attempt token without changing public lifecycle states.
- Concurrent same-monitor starts join one attempt. Cancellation by any waiter cancels that shared attempt for all waiters. Stop invalidates, cancels, and awaits in-flight setup before returning.
- Every setup continuation must validate the attempt token before another acquisition or Running commit. Start and run generations are distinct, so stale setup cannot affect a restart.
- Removed ambiguous maximum-screen capability collection. V1 estimates main-display callback cadence with `CADisplayLink` but marks `display.maximumFramesPerSecond` unsupported because the monitor has no view/window screen context. Deprecated `UIScreen.main` and `UIScreen.screens` are prohibited.

## Correctness and Testing

- Defined a fresh sampling epoch and collector baselines immediately before Running commits.
- The first sample waits one configured interval. Each turn captures its header boundary after wake and before reads, rounds elapsed milliseconds to nearest with exact halves upward, clamps to `1...Int64.max`, and sleeps again only after completion.
- Restart discards the header epoch, CPU baseline, and display accumulator.
- Separated caller-owned state continuations from run resources. Each live subscription owns one newest-one continuation in any state; exact termination removes it, stop/restart preserves it, and monitor deinitialization finishes it.
- Expanded deterministic tests for setup reentrancy, epoch/rounding/restart behavior, unsupported display context, and pre-start/multiple/persistent subscription lifecycle.

## Security, Privacy, Performance, and Documentation

- Changed `NSPrivacyCollectedDataTypeLinked` to true. The privacy decision now covers the complete NearWire envelope and Viewer behavior rather than only the identifier-free snapshot body.
- NearWire deliberately sends the event through a session correlated to a persistent App installation identifier. Documentation and validation must disclose that association while retaining tracking false.
- Added an installation-correlated envelope fixture to the packaged-manifest and generated privacy-report audit.

The linkage decision follows Apple's current [App privacy details](https://developer.apple.com/app-store/app-privacy-details/) definition and the repository's existing installation-correlation contract in `Documentation/SDK-Public-API.md` and `Documentation/Wire-Protocol.md`.
