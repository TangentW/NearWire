# Design

## Context

NearWire already exposes `NearWireReconnectionPolicy`, `suspendConnection()`, and `resumeConnection()`. An active connection owns an in-memory normalized pairing code and connection intent. Suspension cancels the current route and preserves only an already-active intent; resume authorizes a fresh discovery, TLS admission, epoch, sequence state, pump, and process lease. Manual disconnect clears intent and prevents successor work. Recovery is disabled by default so host applications must choose their own lifecycle and energy policy.

The Viewer already implements newest-session-wins transport replacement for the same logical App route and keeps replacement Event state independent. Review found a separate presentation gap: an operator-selected Device filter is stored by per-connection UUID, so it can continue selecting the ended predecessor and hide Events from the accepted successor. The Demo's missing host policy and this stale presentation scope together explain the reported reconnect behavior. A generic SDK cannot safely subscribe to `UIApplication` or one SwiftUI scene because applications may aggregate several scenes differently.

## Goals and Non-Goals

Goals:

- Make the maintained Demo recover after ordinary iOS background suspension without another pairing-code entry.
- Exercise the existing SDK lifecycle API as host application code should.
- Cover the reported post-reconnect Event path on both the fresh SDK route and the Viewer replacement route.
- Preserve an active logical Device selection across exact-route replacement so the fresh Event remains visible.
- Keep recovery bounded and preserve explicit disconnect authority.

Non-goals:

- Keep a TCP, AWDL, or Bonjour route alive while iOS suspends the process.
- Add a background mode, background task, reachability observer, notification observer, or SDK-owned platform lifecycle policy.
- Recover after process termination or persist pairing code, connection intent, retry progress, or Events.
- Change SDK retry algorithms, Viewer route identity, TLS, Event acknowledgement, or delivery semantics.

## Decisions

### The Demo opts into the existing bounded recovery policy

The Demo constructs its sole NearWire instance with six total automatic attempts, a 500-millisecond initial delay, and a four-second maximum delay. These fixed valid values are constructed in one private App factory. The budget remains intent-wide according to the existing SDK contract and does not reset after a brief recovered connection. The policy handles a late terminal callback that arrives only after the App has already returned active; it does not keep the process awake in background.

Initial launch remains manual. An active-scene resume with no retained intent is an SDK no-op. Selecting Disconnect clears the intent, so later active transitions cannot reconnect. Reset and teardown keep their existing stronger disconnect/shutdown behavior.

### SwiftUI scene phase is forwarded by one structured task

`DemoRootView` observes `scenePhase` and uses `.task(id: scenePhase)` to call one MainActor model method. The model forwards:

- `.background` to the driver's async `suspendConnection()`;
- `.active` to the driver's `resumeConnection()`;
- `.inactive` to no action.

The task is owned by SwiftUI and is cancelled when the phase or view lifetime changes, so the Demo adds no task registry or detached lifecycle loop. Existing SDK command precedence handles background/foreground transitions that occur while exact route cleanup is still settling. Inactive is deliberately ignored because permission sheets, calls, control center, and other interruptions should not manufacture a disconnect.

### Recovery uses fresh route state and the existing Event buffer

The SDK never replays bytes accepted by the old transport. Events still owned by the bounded offline queue may drain after the new session becomes active. The Event stream remains instance-lifetime rather than connection-lifetime. On the Viewer, the successful replacement owns a new capability, epoch, queues, and live Event identity; a fresh active Event must be accepted from that exact replacement.

### Viewer selection follows only an active exact-route replacement

Before replacing its session snapshot set, the Event Explorer compares each selected predecessor against the prior snapshots. It migrates a selected connection UUID only when that predecessor was non-recent and the successor snapshots contain a different non-recent connection UUID for the exact same `ViewerLogicalRoute`. This preserves an operator's logical Device focus across an automatic reconnect without merging different App installations or bundle routes, and without retargeting a deliberately selected historical recent row.

The migration occurs before the next memory evaluation and triggers the same bounded selection refresh used by an explicit Device toggle. Existing Timeline rows remain until the successor evaluation publishes, avoiding an empty-container flash.

Focused tests extend existing production seams rather than building a Demo transport simulator:

- the compact Demo test verifies the fixed recovery configuration, then calls background and active and verifies the public suspended/current state without starting discovery;
- the SDK lifecycle test queues an Event while suspended and verifies that the fresh resumed pump transmits it once active;
- the Viewer replacement test selects the active predecessor, performs exact-route replacement, verifies selection migration, and verifies the fresh-epoch Event reaches the live Timeline while the predecessor is no longer authoritative.

## Risks and Mitigations

- **The background task may not finish before iOS suspends the process.** The enabled SDK recovery policy also handles a late terminal callback after foreground return; resume and cleanup races are already generation- and receipt-gated.
- **Automatic recovery can consume energy.** Recovery is limited to six intent-wide attempts with capped delay, stops on permanent failure or exhaustion, pauses in background, and is cleared by manual disconnect.
- **A developer may interpret recovery as background connectivity.** Demo copy and documentation explicitly state that iOS may terminate the route and recovery begins only when execution resumes.
- **The old Viewer route may still be cleaning up.** Existing bounded exact-route replacement makes the successfully attached newest session authoritative and does not transfer old state.

## Verification

- Strict OpenSpec validation before source changes.
- Focused Demo, SDK lifecycle, and Viewer replacement/Event regressions.
- Demo unit suite and SDK/Viewer affected suites as proportionate to the touched boundaries.
- SwiftPM iOS Simulator build and launch smoke; CocoaPods-equivalent source/build validation without committing generated artifacts.
- Real iPhone background/foreground smoke when the currently discoverable device and signing state permit it; otherwise record the exact environment limitation.
- Independent architecture/API, correctness/testing, and security/performance/documentation reviews, followed by a fresh clean round.
