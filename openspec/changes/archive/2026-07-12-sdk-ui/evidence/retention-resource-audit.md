# Retention and Resource Audit

Date: 2026-07-12

## Per Presented Panel

- one `NearWireUIConnectionModel` on `MainActor`;
- one latest-value SDK status subscription;
- one coordinator phase registration with `AsyncStream.bufferingNewest(1)`;
- one bounded pairing string of at most 64 UTF-8 bytes;
- one latest status, one coordinator phase, and at most one safe action error;
- no model-owned action Task, timer, history, callback list, or persistence.

`start()` is idempotent. `stop()` advances status, phase, and action generations; unregisters the exact phase token before cancelling observations; cancels observations; invalidates the exact UI Connect token; and clears input, error, and status. Deinitialization synchronously removes the exact coordinator registration and cancels an exact UI Connect through lock-protected storage before cancelling both observations. It creates no cleanup Task and retains no model.

## Per Controller Identity

One process-local `@MainActor` coordinator entry contains:

- one closed phase;
- zero or one Connect operation with one Task, exact token, bounded one-shot code capture, and zero or one weak-model origin completion;
- zero or one code-free Disconnect operation with one Task and exact token;
- one continuation per live panel, each buffering only its newest later phase.

Connect starts only from idle. Cancel/Disconnect clears the origin callback, cancels the exact Connect Task, and starts or joins one Disconnect Task. The entry cannot return to idle until both exact operations acknowledge completion. An idle entry is removed only after both operation slots and every exact subscriber are gone. A deliberately noncompleting SDK cleanup therefore remains fail-closed with one route/controller, one code-free Disconnect Task, and no expanding waiter list.

Automated tests prove duplicate activation suppression, simultaneous-panel coherence, exact explicit and natural subscriber removal, repeated start/stop, weak-model release, synchronous release during Connect, 100-model burst cleanup, controller release after exact completion/unsubscribe, both preemption completion orders, fail-closed repeated Disconnect joining, and the Connect A/disappear/recreate/Connect B gate.

## Forbidden Resources and Side Effects

The production UI source contains no UIKit, AppKit, Objective-C surface, public Combine API, UserDefaults, file persistence, Keychain or Security item operation, pasteboard, camera, analytics, reachability, NotificationCenter, application lifecycle observer, background task, custom resource, asset, font, entitlement, privacy declaration, third-party import, detached Task, or absolute screen geometry.

Foundation is imported only by the internal coordinator for `NSLock`. The lock protects bounded in-memory state only; task cancellation, stream delivery/termination, and origin completion are prepared while locked and executed after unlocking. Each phase mutation advances one per-entry revision. An unlocked delivery re-reads the latest phase and repeats only when a newer revision raced its external yield, so the final bounded latest-value stream cannot remain on an older phase. Automated reentrant-cancellation, publication/termination, and forced reverse-delivery tests cover this boundary.

Construction starts no observation or operation. Presentation never creates a `NearWire` instance and does not call suspend, resume, or shutdown. Disappearance does not disconnect an active session.

`Scripts/check-sdk-ui-structure.rb`, focused strict tests, Package.swift/podspec graph checks, SwiftPM external consumer checks, and same-module CocoaPods UI compilation provide automated evidence.
