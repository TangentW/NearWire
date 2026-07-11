# SDK Process Connection Lease Design

## Context

`NearWire` is instance-based by design. Multiple instances may buffer unrelated events and own independent subscriptions, but only one instance may progress toward a Viewer connection in a host App process. A check-then-set Boolean on each instance cannot enforce that invariant, and an actor-only registry would make acquisition unnecessarily asynchronous. A normal Swift static is scoped to one loaded module image, so it also cannot substantiate an unconditional process-wide guarantee when NearWire is embedded in more than one dynamic image.

This change provides only the ownership primitive. A later public connection orchestrator will claim it before discovery and retain the returned handle through discovery, TLS admission, the active session, and bounded reconnection. That orchestrator remains responsible for mapping every internal lease error, including contention and runtime-unavailable, to supported safe SDK errors and invoking exact-handle release on every terminal path.

## Goals and Non-Goals

Goals:

- Linearize competing claims synchronously across threads, actors, and loaded NearWire images.
- Give exactly one live handle authority to release the current claim.
- Make stale, repeated, concurrent, and deinitialization releases harmless.
- Keep construction and ordinary event use free of global ownership side effects.
- Keep the primitive internal, bounded, dependency-free beyond Apple system frameworks, and deterministically testable.

Non-goals:

- Public `connect` or `disconnect` APIs.
- Per-instance connection state or repeated-connect policy.
- Pairing, discovery, transport, handshake, flow policy, event draining, or incoming delivery.
- Reconnection grace periods or transfer of a lease between instances.
- Persistence, installation identity, logs, metrics, timers, tasks, or App lifecycle observation.

## Decisions

### 1. Bootstrap one private process monitor

The SDK permanently reserves two exact Objective-C selector literals:

```text
com.nearwire.connection-lease.monitor
com.nearwire.connection-lease.owner
```

These ownership namespace strings are independent of SDK, product, protocol, schema, and build versions and must never change between compatible or coexisting releases. If migration is ever unavoidable, one monitor operation must inspect every legacy owner slot before claiming and must continue coordinating legacy releases; introducing a new uncoordinated slot is forbidden.

Each loaded NearWire image creates an immutable local `@unchecked Sendable` runtime-reference object. Resolution creates a candidate private `NSObject` before briefly synchronizing on `ProcessInfo.processInfo`. After a successful enter, bootstrap reads the monitor association, or installs the candidate under the permanent monitor selector using retain-nonatomic policy, and records only the selected monitor reference and a primitive outcome. Bootstrap explicitly exits before constructing an available or unavailable runtime reference and before releasing the losing candidate. When all bootstrap statuses succeed, every image retains the same private monitor object. Normal claim and release synchronize only on that private monitor, never on the public ProcessInfo singleton, and read or update its associated owner token under the permanent owner selector with retain-nonatomic policy.

Every `objc_sync_enter` and `objc_sync_exit` status is checked, with distinct failure phases. A failed bootstrap enter performs no associated-object access and produces an unavailable runtime reference after the failed call. A failed bootstrap exit may already have read or installed the monitor; it produces an unavailable runtime reference without inspecting, rolling back, releasing, or otherwise touching the association after the failed exit. A failed private-monitor enter performs no owner-slot access: claim returns runtime-unavailable, while release leaves the owner slot untouched. A failed private-monitor exit may already have read or mutated the owner slot: claim fails closed and never returns a handle, while release provides no success or later-reacquisition guarantee and never creates a second owner. Every failed claim status uses the same separate fixed runtime-unavailable error. These failures may make connection ownership unavailable, but never permit two successful owners.

There is no mutable Swift global, `nonisolated(unsafe)` storage, supported `shared` object, service locator, notification, environment key, configurable registry instance, or force-reset API. Same-process Objective-C runtime code is inside the trust boundary: the selector literals are stable namespaces, not secrets, and hostile host code could reproduce or tamper with them. Exact-token identity protects against stale NearWire handles, not malicious code executing inside the host process.

The synchronization algorithm is expressed as one internal low-level operation over an internal runtime-operations protocol. The production registry is not configurable and always delegates to the fixed Apple-system adapter and process anchor. Tests may invoke the exact same low-level operation with a test-only adapter and an isolated `NSObject` fixture. The seam carries no caller closure or application content, is not public or SPI, and cannot replace the production registry's adapter or anchor.

Creating `NearWire`, sending an event, subscribing to streams, or constructing another internal value does not touch the runtime anchor. Only a later explicit connection operation calls claim.

### 2. Exit the runtime monitor before returning an outcome

Claim resolves its immutable runtime reference and creates one private `NSObject` token before entering the private monitor. While synchronized, it reads the owner association and, only when absent, stores the new token and records a primitive success Boolean. It explicitly exits before constructing or returning a handle, constructing or throwing an error, formatting diagnostics, or performing cleanup. If all required synchronization statuses succeed and the slot was empty, claim returns a handle. If all required statuses succeed and a token was current, claim throws one fixed `anotherConnectionIsActive` internal error after exit and retains no rejected token or caller data. Any bootstrap or private-monitor enter/exit failure instead throws the separate fixed runtime-unavailable error regardless of the observed slot contents.

The private monitor protects a constant amount of state and performs only associated-object get/set and primitive outcome recording while entered. It invokes no user closure, handle/error initializer, allocation-heavy work, async continuation, logging, diagnostic formatting, or cleanup. Claim has no suspension point. Concurrent callers and independently loaded NearWire images therefore observe one total order, and at most one succeeds.

### 3. Release only by exact token identity

The opaque handle retains its private monitor reference and token. `release()` enters that private monitor, clears the owner association only when the current value is the identical object, and explicitly exits before any cleanup. When required synchronization statuses succeed, a repeated release, a stale handle releasing after a newer claim, or concurrent releases are no-ops. Release does not expose whether another claimant currently exists or whether a synchronization failure occurred. Failed enter leaves the owner slot untouched. Failed exit may follow a clear but provides no success or reacquisition guarantee.

The handle also calls the same idempotent release from deinitialization as defensive cleanup. Explicit lifecycle release remains the primary path. The runtime anchor never retains the handle itself, so no ownership cycle prevents deinitialization.

### 4. Keep handle use concurrency-safe and content-free

The handle is an internal `@unchecked Sendable` final class whose safety rests only on the runtime monitor and immutable token reference. It contains no instance ID, pairing code, endpoint, Viewer identity, event data, closure, task, timer, or continuation. Description, debug description, interpolation, and reflection expose only a fixed safe label.

The internal error contains a stable code and fixed message without type names, memory addresses, tokens, instance counts, or application content.

### 5. Preserve instance-local behavior and future owning shutdown

The lease governs only permission to own future connection work. It does not merge NearWire instances, queues, streams, configuration, IDs, statistics, or shutdown. Releasing a lease does not clear an event queue or publish state. Claim failure does not mutate either the current owner or the rejected instance.

In the current disconnected facade, a NearWire instance owns no lease, so its shutdown changes no lease state. A later owning connection or session shutdown must deterministically invoke release on its own exact handle. Successful synchronization clears ownership; a synchronization failure remains fail-closed and may leave connection ownership unavailable. Shutdown of any unrelated instance can never release another owner.

## Operation Table

| Private monitor state | Operation | Result |
| --- | --- | --- |
| empty and all statuses succeed | claim | Store new token under the runtime monitor, exit, then return its handle. |
| held by token A and enter/exit succeed | claim | Exit, then throw fixed contention error; A remains current. |
| held by token A and enter/exit succeed | release A | Clear current token and exit. |
| held by token A and enter/exit succeed | release stale token B | Exit without mutation; A remains current. |
| empty and enter/exit succeed | release any token | Exit without mutation. |
| any | concurrent calls or loaded module images | Linearize through the same private monitor and permanent owner slot. |
| bootstrap enter fails | resolve | Access no association; construct an unavailable reference after the failed call. |
| bootstrap exit fails | resolve | Construct an unavailable reference after the failed call; do not inspect or roll back the association. |
| private-monitor enter fails | claim | Access no owner slot; fail closed with fixed runtime-unavailable error. |
| private-monitor exit fails | claim | Return no handle and throw runtime-unavailable regardless of the observed slot state. |
| private-monitor enter fails | release | Access no owner slot and provide no success signal; current ownership is unchanged. |
| private-monitor exit fails | release | Provide no success or reacquisition guarantee; the exact token may already have been cleared. |

## Test Strategy

- Every in-process test enters one external test-only serial suite gate that is not stored in or callable by production code. It proves initial claimability, uses scope or `defer` cleanup for every successful handle, and proves final claimability before exit. There is no force-reset API.
- Sequential tests prove first claim, contention, explicit release, reacquisition, repeated release, and deinitialization release.
- A stale-handle ABA regression proves an old handle cannot clear a later token.
- Concurrent first-claim tests retain all successful handles until the cohort joins and prove exactly one success without sleeps.
- Claim/release race tests retain every racer success until join and assert at most one. A post-race probe succeeds exactly when no racer succeeded and otherwise receives contention; after releasing a retained winner, a final probe succeeds. Concurrent repeated release and stale-release cases are separate.
- A macOS validation harness builds two dylibs separately, each compiling its own copy of the production lease source and a uniquely named C-callable wrapper. It dynamically loads both images and proves the permanent selector literals, shared private monitor, cross-image contention, exact release, stale release, and reacquisition.
- Test-only runtime adapters exercise bootstrap-enter, bootstrap-exit, claim-enter, claim-exit, release-enter, and release-exit failure branches against isolated `NSObject` fixtures. Claim-exit coverage includes both an initially empty slot whose token was just installed and a pre-populated slot, proving runtime-unavailable takes precedence over contention while preserving the existing token identity. Release coverage proves failed enter leaves the slot untouched and failed exit exposes no success or reacquisition guarantee. Intentionally unreleasable fixture tokens die with their fixtures and never touch or reset the real process slot. A structural audit proves the non-configurable production registry delegates to that exact operation using only the fixed Apple-system adapter and process anchor.
- Structural and exported-symbol audits also prove bootstrap and claim construct outcomes and perform cleanup only after exit; failed enter never accesses a slot; failed exit never returns a handle; wrapper sources, loader code, generated dylibs, and test adapters stay outside `SDK/Sources`, package and pod globs, and distributable binaries. Package product and target inventories remain unchanged, and distributable binaries export no harness wrapper symbol.
- Redaction and reflection tests prove no token or address escapes.
- Existing multi-instance queue, stream, shutdown, SwiftPM/CocoaPods consumer, and API-inventory gates prove the public instance model remains unchanged.
