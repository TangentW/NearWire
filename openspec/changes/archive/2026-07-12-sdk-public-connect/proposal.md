## Why

NearWire now has all internal pieces required for one live App session: exact pairing discovery, mandatory TLS admission, one process-wide connection lease, and a bounded bidirectional active Event pump. Application code still cannot start that path, observe its real phases, or receive stable public errors. A narrow public orchestrator is required before lifecycle policy, UI, and performance collection can build on the SDK.

## What Changes

- Add one explicit instance method, `connect(code:)`, that validates the request, reserves exact instance ownership, claims the process connection lease, constructs the App hello, runs admission, activates the existing Event pump, and returns only after the session is connected.
- Add a bounded off-actor Keychain operation that loads or creates one application-scoped installation identifier only after an explicit attempt owns the lease. Pairing codes remain memory-only and all public-orchestrator references are released after admission takes discovery ownership.
- Add a pre-lease connection-limit planner that keeps queue-accounting, Event-record, frame, secure-mailbox, and active-turn byte domains distinct and rejects an unsupported public configuration with `invalidConfiguration`.
- Publish exact `discovering`, `connecting`, `connected`, and `disconnected` states through the existing current-state and latest-value stream APIs. Keep `reconnecting` unused in this change.
- Map every error observable before `connect(code:)` succeeds into a closed set of content-safe public codes. After success, active terminal causes publish only `disconnected`; terminal-reason observation remains lifecycle scope.
- Retain the exact process lease through pre-admission operation completion or active-core terminal state. Task cancellation keeps the attempt slot until its current operation releases; shutdown detaches public state immediately while a non-public cleanup owner finishes. Every release regime invokes exact-handle cleanup, and Objective-C runtime synchronization failure remains fail-closed.
- Keep public disconnect, automatic reconnect, App lifecycle observation, background behavior, UI, pairing-code or Event persistence, and performance collection out of scope for their later dedicated changes.

## Capabilities

### New Capabilities

- `sdk-public-connect`: Explicit one-attempt public connection orchestration, coherent connection limits, App hello identity, safe errors, state publication, exact active ownership, and terminal cleanup.

### Modified Capabilities

- `sdk-public-boundary`: `connect(code:)`, its documented public errors, and connection state behavior become supported and equivalent through SwiftPM and CocoaPods while implementation types remain hidden.
- `sdk-async-facade`: The existing facade publishes real one-attempt connection phases and makes shutdown/deinitialization detach public ownership and request exact cleanup without overclaiming immediate internal termination.
- `sdk-process-connection-lease`: The public orchestrator becomes the only supported path that claims the lease and retains it until attempt completion or active terminal cleanup before invoking exact release.
- `sdk-session-admission`: Admission provides one shared lifetime termination value plus a bounded tokenized phase authorization checked synchronously after suspension, so the public owner can observe terminal state once and publish `connecting` safely.
- `sdk-active-event-pump`: Active binding captures immutable local rate policy and uses weak owner operations, eliminating every permanent-core-to-NearWire strong edge while preserving owner-unavailable terminal behavior and exact wake cleanup.

## Impact

The change affects the supported NearWire API, SDK-only orchestration, Security.framework identity code, public consumer fixtures, tests, documentation, and validation scripts. It adds no product, target, subspec, entitlement, privacy declaration, or third-party dependency. Existing Event APIs remain source-compatible. Public disconnect, reconnection, and terminal-error observation remain roadmap item 13.
