# Task 3.3 Bounded Live Projection Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerLiveEventWindow` now owns a preallocated 64-record ingress ring with a 20-MiB
  deterministic-accounting limit. Each entry accounts the precomputed Event bytes plus a documented
  32-KiB maximum reserve for bounded metadata and fixed fields. The reserve is explicitly not a
  Swift-heap guarantee; it admits one 16-MiB maximum legal Event and also permits 512 minimum-sized
  entries inside the retained 32-MiB limit.
- A callback offer performs a bounded header comparison, exact-key dictionary lookup, ring update,
  and scheduling-state update. It performs no JSON encoding/traversal, SQLite work, MainActor wait,
  per-Event task creation, eviction, or large-value release. Equal durable headers defer the only
  potentially large canonical-content comparison to the projection executor; a differing persisted
  header is already an exact conflict. Equality still compares the full durable projection and never
  trusts a hash.
- The first exact key fans out to the store in callback order. Same-header duplicates wait for the
  serial projection comparison before store fan-out. This preserves durable writer order while
  keeping content traversal off the callback lock. Ingress rejection remains `untracked` and relies
  only on the existing durable authority.
- One `drainScheduled` owner and one `dirtySuccessor` bit feed one serial projection queue. A focused
  blocked-queue test offered 65 Events and observed exactly one drain schedule, one dirty successor,
  one drain run, one maximum concurrent drain, and one snapshot publication.
- The retained window is a fixed-slot doubly linked deque with an exact-key index and free-slot
  stack. Append, key lookup/removal, and oldest eviction are O(1). It retains at most 512 Events and
  32 MiB; evicted values are detached and released on the projection executor, outside callback
  locks, and no tombstone remains.
- The bounded authority index retains only content-free durable headers plus pending ownership. It
  preserves order across eviction/deferred-duplicate races, promotes the oldest bounded pending
  candidate when the earlier value leaves the window, and removes the key when neither retained nor
  pending ownership remains.
- Immutable snapshots include ordered Events, at most 16 frozen session metadata rows, exact later
  disposition, per-device positive cumulative drops, session end, durable state, resident conflict,
  ingress/window/diagnostic gaps, and store unavailable/recovery state. Store status signals are
  routed from the process store through the application to the projection executor without touching
  protocol state.
- Accepted store outcomes remain transient as `acceptedAwaitingVisibility` until the exact durable
  row is reported visible. Identical removes only the exact later candidate. Journal conflict removes
  that candidate and inserts a bounded exact-key marker. Unavailable keeps the candidate as
  `notRecorded`; later accepted/status recovery closes the bounded store gap.
- A latest-only refresh scheduler retains at most one wake, delivers no more often than every
  100,000,000 nanoseconds, runs on the MainActor in production, coalesces to the newest snapshot
  generation, and schedules/delivers nothing while presentation is paused or sealed.
- Runtime shutdown first seals and joins live ingress so deferred duplicate decisions fan out before
  durable journal shutdown. It then waits for durable completion, clears all Event/session/control
  state on the projection executor, invalidates pending wakes, and only then completes the existing
  cleanup receipt. Snapshot/window/session/gap roots expose redacted, content-free reflection.

## Focused live-projection validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testCommittedObservationComparatorAndLiveIngressPreserveTheFirstValue -only-testing:NearWireViewerTests/ViewerFoundationTests/testRuntimeComponentsKeepOneTypedManagerAndClearLiveStateAfterDurableShutdown -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveIngressAdmitsOneMaximumEventAndRejectsTheTwentyMiBOverflow -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveRefreshIsLatestOnlyTenHertzAndPausedPresentationSchedulesNothing
```

Result: `TEST SUCCEEDED`; 5 tests executed, 0 failures.

The tests cover exact duplicate/conflict fan-out, ingress count/byte rejection, one maximum legal
Event, 512-record eviction, no-tombstone horizon loss, drain/dirty/snapshot operation counts,
session/drop/disposition/store transitions, exact durable visibility, immutable/redacted snapshots,
latest-only refresh, the 10-Hz interval, paused presentation, and joined runtime clearing.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 204 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate. The other is the opt-in Application Support artifact
audit that requires its machine-local marker.

## Static and specification validation

- `xcrun swift-format lint --strict` passed for all production and test files affected by task 3.3.
- `git diff --check` passed.
- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  reported `Change 'viewer-event-explorer-control' is valid`.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64`; this evidence does not claim configured signing passed.
