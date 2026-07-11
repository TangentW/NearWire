# SDK Public API

## Why

NearWire has validated event, flow-control, wire, and secure-transport primitives, but an iOS application still has no supported API that it can adopt. The SDK boundary must be designed before discovery work so application code depends only on stable NearWire-owned values, asynchronous streams, and an instance facade rather than on Core, transport, or session implementation details.

## What Changes

- Add an instance-based `NearWire` actor with side-effect-free construction, explicit shutdown, isolated per-instance state, and no singleton.
- Add supported public configuration, event, content, priority, delivery policy, send-result, buffer-diagnostics, state, and safe error values without leaking internal module types.
- Add generic Codable send and decode APIs, normal and keep-latest buffering, instance/session-affine causal replies, deterministic validation, and explicit local-admission semantics.
- Add bounded in-memory uplink buffering before a Viewer is connected, priority-aware overflow, TTL expiration, and actor-isolated internal drain seams for the later session change.
- Add multi-subscriber Swift concurrency state and incoming-event streams with bounded buffering, deterministic slow-consumer failure, and terminal shutdown behavior.
- Hide Core declarations behind a repository-only SPI, add a narrow built-in-event SPI for optional NearWire modules, and verify equivalent iOS SwiftPM/CocoaPods consumer surfaces.
- Extend the internal fair queue and secure byte channel with transactional candidate offering and synchronous bounded mailbox admission so the later session coordinator has a race-free handoff boundary.

## Capabilities

### New Capabilities

- `sdk-event-api`: Public JSON-compatible event values, typed Codable conversion, send options/results, replies, and safe errors.
- `sdk-offline-buffer`: Bounded actor-owned offline uplink admission, coalescing, TTL, overflow, diagnostics, and later-session drain seams.
- `sdk-async-facade`: Instance actor lifecycle, current state, bounded multi-subscriber AsyncSequence delivery, isolation, and shutdown.
- `sdk-public-boundary`: Stable NearWire-only signatures and equivalent SwiftPM/CocoaPods consumer compilation.

### Modified Capabilities

- `bounded-event-queue`: Preserve fair ordering and scheduler credit when synchronous transport admission stops on a candidate.
- `secure-byte-channel`: Add concurrent, synchronous, bounded mailbox admission with explicit byte-ownership transfer and terminal cleanup.

## Impact

- Replaces the NearWire SDK module marker with its first supported public API while preserving the package and pod dependency graphs.
- Adds SDK implementation under `SDK` and the narrow queue/channel handoff primitives under `Core`, with deterministic tests and documentation for both boundaries.
- Does not implement Bonjour, pairing-code normalization, a process-wide connection lease, real network connection methods, negotiation, reconnect, background transitions, UI, performance collection, persistence, or Viewer behavior. Those remain in their named roadmap changes.
