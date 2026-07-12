# Pre-Implementation Architecture and API Review — Round 2

## Scope

Re-reviewed the remediated proposal, design, both delta specifications, tasks, current supported lifecycle/status API, Swift Package and CocoaPods mappings, NearWireUI shell, and the Round 1 architecture/API findings. This is report-only; no production, test, specification, or documentation source was modified.

## Round 1 Finding Disposition

- **Disconnected retained intent:** resolved. The UI now uses a conservative public-status action matrix, offers optional Disconnect/reset beside Connect for disconnected error presentation, and exposes reset after ownership preflight errors without inferring private intent (`design.md:45-50,64-66`; `specs/sdk-ui/spec.md:66-78`).
- **CocoaPods parity:** resolved. The boundary now compares the CocoaPods UI-installed aggregate with combined SwiftPM NearWire plus NearWireUI inventories and separately checks the exact UI declaration delta; SDK-only and UI-installed consumer fixtures are distinct (`specs/sdk-public-boundary/spec.md:3-21`).
- **Injected-instance replacement:** resolved. A stateless public wrapper keys the state-owning child by `ObjectIdentifier(nearWire)`, with explicit old-generation teardown and replacement tests (`design.md:41-43,99-102`; `specs/sdk-ui/spec.md:116-123`).
- **Async action bound:** substantially improved. Immediate Disconnect now uses a bounded exact-controller coordinator rather than pretending a cancelled Connect has terminated. One residual Cancel ownership gap remains below.

## Findings

### P1 — High: Cancel has no cancellation-acknowledgement state, so the one-predecessor bound is not closed

The remediation distinguishes Cancel from Disconnect. Cancel advances generation and cancels the Connect Task without starting the shared Disconnect coordinator (`design.md:54-64`), while the total action rule says a panel-owned Connect offers Cancel and an idle/error-free disconnected presentation offers Connect (`design.md:66`; `specs/sdk-ui/spec.md:45-49,66-68`). The SDK may preserve its prior stable `idle` or `disconnected` status during pre-discovery work, and cancellation is explicitly acknowledged only after async cleanup.

The artifacts do not say that the cancelled Task handle remains an exact model-owned “Cancelling” gate until completion, nor do they define such a presentation. If Cancel clears current-action ownership immediately, the unchanged public status re-exposes Connect while predecessor A remains live. Starting and cancelling B can then leave two cancelled predecessors, violating the hard one-predecessor bound (`design.md:60,80-84`; `tasks.md:17-23`). If the handle remains current, the specified action matrix continues to expose Cancel for an already-cancelled Task and does not define when or by what exact identity that resource gate clears. Action generation cannot solve resource ownership because the stale completion is otherwise required to be inert.

Action: add an exact cancellation-acknowledgement token/handle and a total post-Cancel state. The narrow options are either (a) retain the exact cancelled Connect as a disabled `Cancelling` gate until that Task's completion clears only its matching resource slot, or (b) route Cancel through the same cancel-plus-shared-Disconnect path and show `Disconnecting`. In either case, no new Connect may start while the predecessor exists; stale completion must remain unable to change input/error/status. Add a held pre-discovery Cancel, repeated Cancel/Connect, and disappearance/reappearance winner matrix proving the live predecessor count never exceeds one.

### P2 — Medium: The new global coordinator contradicts the current no-singleton public requirement

The architecture now deliberately requires one internal process-local coordinator shared across panels and keyed by controller object identity (`design.md:60-64,80-84`; `specs/sdk-ui/spec.md:45-64`; `tasks.md:8-10`). That is implementable in Swift 5 as an internal `@MainActor` registry: a synchronous main-actor request can install one Task, the `Sendable` class-bound controller may be captured across its async disconnect, and exact entry identity can govern removal. It also preserves injection because it creates no controller or NearWire instance and keys only the exact injected object.

However, the same supported requirement still says NearWireUI shall create no “singleton” (`specs/sdk-ui/spec.md:3-5`). The coordinator is process-global state and its Task strongly retains the injected controller until disconnect returns, potentially forever at the SDK's deliberate fail-closed boundary. The later resource requirement permits that retention, but the public ownership requirement does not carve it out. An implementation cannot satisfy both literally, and a boundary audit could reject the chosen architecture.

Action: make the allowance exact. Replace the blanket singleton ban with a ban on a global/singleton NearWire facade or constructed SDK instance, while permitting one internal main-actor disconnect registry that stores only exact controller identity plus one code-free Task, creates no controller, exposes no API, owns no pairing/status/error/route state, removes successful entries by exact token, and retains the controller only for the bounded async call or documented fail-closed noncompletion. Add source/retention tests proving those limits and ObjectIdentifier reuse safety.

## Additional Architecture/API Recheck

- The conservative disconnected action policy now composes correctly with default-disabled retained intent and permanent no-intent terminal states without broadening the lifecycle API.
- Aggregate-plus-delta packaging parity matches the actual separate SwiftPM modules and single CocoaPods module while keeping the CocoaPods SDK default unchanged.
- ObjectIdentifier-keyed child replacement preserves exact injection without requiring host `.id` choreography; old and new models cannot share mutable state.
- The public two-view API remains narrow and feasible under Swift 5 complete concurrency for iOS 16 and macOS 13. Internal presentation fixtures and a direct test-only NearWire dependency avoid adding a public status initializer.
- The global coordinator does not inherently create a second SDK instance or network owner; its remaining issue is the unresolved contract language and exact retention allowance above.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Changes required. Unresolved actionable findings: 2 (1 high, 1 medium). Pre-implementation architecture/API approval remains withheld until Cancel has an exact acknowledgement gate and the internal coordinator is reconciled with the no-singleton/injection contract.**
