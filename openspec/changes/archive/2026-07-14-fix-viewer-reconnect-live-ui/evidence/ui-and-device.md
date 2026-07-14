# UI and Device Evidence

Date: 2026-07-15

## Offscreen macOS UI verification

The Viewer UI was rendered through `NSHostingView` inside XCTest because direct desktop capture was not authorized in this environment.

- Analysis workspace: the test captured PNG data in Events mode, switched the observed coordinator to Performance, yielded publication, captured again, and verified the rendered images differed without another Event or application-model update.
- Filter sheet: the expanded sheet rendered at 620 by 660 points with Event, direction/priority, receive-time, JSON, and diagnostics groups. The test verified all five custom inputs, stable vertical separation, a bounded scroll container, and retained a screenshot attachment named `NearWire Filters expanded minimum layout`.
- The exported screenshot was visually inspected. Sections and date controls were aligned, the JSON area remained inside the scrollable content, and the bottom Close/Apply actions remained reachable.

## Physical-device boundary

The user stated that the iPhone was no longer connected and was unavailable for a physical-device run. `ios-vibe-harness devices` reported no booted simulator and one paired physical-device record, but no USB-attached device was authorized for interaction, so no phone action was attempted. The final reconnect and cellular/AWDL behavior therefore remains explicitly pending a later real-device smoke test.

## Cellular and peer-to-peer diagnosis

Earlier logs from this investigation showed that the established secure connection used TLS 1.3 with ALPN `nearwire/1` over `awdl0`. Enabling cellular did not carry NearWire traffic over the public cellular Internet; Apple Wireless Direct Link remained the peer-to-peer data path.

The logs exposed two distinct conditions:

1. A second exact logical route could be rejected or leave an older route owner authoritative while a reconnect was attempting to take over. The session-manager change now commits the newest successfully attached exact-route session, retires the predecessor capability, and cleans the predecessor outside the manager lock.
2. One capture later reported the AWDL path as unsatisfied with `No network route` about 71.8 seconds after readiness. That is a separate post-connect link-viability condition. Existing transport semantics preserve post-ready recovery by moving through preparing/waiting rather than misclassifying it as a new TLS failure, but recovery of the real radio path cannot be proven without the phone.

A prior test-host Viewer process also accepted one phone connection during diagnostics, which explained why the visible Viewer did not receive that run's Events. Final UI tests use deterministic in-process fakes and do not start a competing network listener.
