# SDK UI Implementation Security, Performance, and Documentation Review — Round 4

## Scope

Independently reviewed the complete active `sdk-ui` change after Round 3 remediation: production source, focused tests and test support, package and CocoaPods validation, active proposal/design/specifications/tasks, UI and distribution documentation, prior reviews, remediation record, and final evidence. The review specifically traced revision-based unlocked delivery convergence and boundedness, the delivery test hook's production impact, pairing/token cleanup under latest-value coalescing, reentrant observer release, fixed-English and dependency boundaries, portable API normalization, and consistency of the 42/469 validation record. Only this report was added.

## Round 3 Remediation Verified

- Each phase mutation advances one per-entry revision. Delivery snapshots the current phase, revision, and exact subscribers under the lock; invokes the optional test hook and `AsyncStream.Continuation.yield` after unlocking; and repeats when a newer revision raced the yield. A forced reverse Cancelling/Disconnecting order converges to the coordinator's current phase. The newest-one stream and exact terminated-subscriber reconciliation remain bounded.
- The delivery hook is an internal type accepted only by the internal coordinator initializer. The process-wide production coordinator uses the default `nil` hook, so it retains no hook closure and executes no hook work. It adds no public/SPI declaration, task, framework, persistence, or host callback. Its use is proportionate to deterministic race testing.
- Task cancellation, stream yield/finish, and origin completion remain outside `NSLock`. No lock-protected external call, reentrant cancellation deadlock, per-panel cleanup task, waiter list, or expanding callback list was found.
- The reentrant-cancellation test now clears its installed observer and weakly proves both its fake controller and coordinator release. No equivalent production retain cycle was found.
- Pairing input remains memory-only, scalar-boundary capped at 64 UTF-8 bytes, absent from logging/persistence/pasteboard/error interpolation/public API, and documented without a secure-zeroization claim. Unexpected errors remain content-safe.
- Fixed strings use explicit verbatim/value SwiftUI paths. Imports remain exactly Foundation, NearWire, and SwiftUI; Foundation is used only for bounded in-memory synchronization. No third-party dependency, resource bundle, asset, font, entitlement, privacy declaration, persistence, Keychain/Security item operation, camera, analytics, reachability, notification, App lifecycle observer, background execution, UIKit/AppKit production wrapper, public Combine API, or detached production Task was found.
- API validation now compares the two source-authored view contracts semantically while ignoring compiler-synthesized attributes and marker conformances. It still rejects source-authored attributes, extra conformances, extensions, members, and declarations.
- Evidence consistently records 42 focused UI tests, 469 full macOS tests with seven existing skips, 469 iOS tests with 465 passes and four existing skips, and successful package and CocoaPods gates. Manifest hashes and recorded tool identities match the current files and tools.

## Finding

### Medium — Latest-value phase coalescing can clear the origin token without clearing the cancelled pairing input

**Confidence: 10/10**

`NearWireUIConnectionModel.receivePhase` now correctly checks whether its exact `activeOperationToken` still owns the coordinator's origin completion. When ownership has been revoked, it clears the token and advances the action generation (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-198`). Pairing input and action error, however, are cleared only when the particular delivered value is Cancelling or Disconnecting (`NearWireUIModel.swift:199-202`).

The coordinator phase stream intentionally uses `AsyncStream.bufferingNewest(1)` (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:417-438`). Therefore, after panel B preempts panel A's Connect, both exact operations may acknowledge before A's phase Task consumes the transient Disconnecting update. Idle may legally replace Disconnecting in the one-value buffer. On that Idle update A detects revoked origin ownership and clears its token, but its previous pairing code remains in memory and the UI returns to an enabled Connect presentation prefilled with the cancelled code.

This violates the requirement that a Cancel/Disconnect request clear model input (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:31-33`) and the Round 3 remediation claim that shared cancellation clears the initiating panel's bounded input. It is also a data-minimization regression: a value whose operation was explicitly cancelled survives longer than the documented clearing boundary.

The current two-panel test cannot expose the defect because it waits until both models visibly consume Disconnecting before completing either operation (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:489-533`). The reverse-delivery test proves eventual phase convergence, but not input cleanup when an intermediate phase is coalesced away.

**Required remediation:** treat exact origin revocation itself as the pairing-input and action-error clearing boundary, regardless of which current phase reveals that revocation. Keep the clearing token-exact so an old operation cannot erase successor input. Add a deterministic test that prevents the origin panel from consuming Disconnecting until both Connect and Disconnect reach Idle, proves the stream coalesces to the latest phase, and asserts the old token, pairing code, and action error are cleared before a new Connect can be submitted.

## Validation Performed

- Strict NearWireUI suite with complete concurrency checking and warnings as errors: **PASS**, 42 tests, 0 failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.
- Current Package.swift and podspec SHA-256 values match `run-identity.md`.
- Focused source scan found no forbidden resource, persistence, logging, detached-production-task, or localizable-literal use.

## Verdict

**Changes required. Unresolved actionable findings: 1 Medium.** Revision-delivery convergence, lock safety, delivery-hook isolation, bounded retention, reentrant observer release, fixed-English rendering, portable API validation, and the recorded validation counts are otherwise approved. Completion remains blocked until exact shared cancellation clears the origin model's bounded input even when the transient cancellation phase is coalesced away, followed by a fresh review.
