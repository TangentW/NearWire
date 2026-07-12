# Pre-Implementation Security, Privacy, Performance, Distribution, and Documentation Review — Round 4

## Findings

No actionable finding remains in the revised pre-implementation artifacts.

## Transition-Gate and Locking Audit

The new shared transition contract closes the terminal-versus-transfer and terminal-versus-connected-commit windows without creating a second terminal authority.

- Admission creates exactly one `SDKSessionLifetime` containing the permanent cancellation relay, one one-shot termination value, and one transition gate. Admitted owner, attachment, active handle, post-admission attempt, coordinator, and actor commit share those exact objects.
- The permanent core calls `markTerminal(code:)` synchronously at its exact first terminal transition, before waiter resumption, asynchronous channel cleanup, or callbacks. Delayed scheduling of the sole waiter therefore cannot turn a terminal-first ordering into a transfer or connected-commit win.
- `markTerminal`, `claimActiveTransfer`, and `claimConnectedCommit` use the same lock. The first successful operation defines the specified row. The actor performs a successful connected claim, owner installation, connected publication, and success return in one no-suspension turn.
- Before handoff, the attempt gate alone owns cancellation and the lease. The only nested lock order is attempt gate then session gate. Handoff installs one permanent redirect, copies a latched task/shutdown reason, receives session ownership acknowledgement, and only then clears attempt ownership.
- No post-handoff operation acquires the locks in reverse order. Later cancellation routes to the session gate, and process-lease release occurs only after the relevant gate has returned its ownership decision. The Objective-C lease monitor is not part of the attempt/session nested critical section.
- Cancellation relay calls, waiter resumption, channel cleanup, weak terminal delivery, actor state mutation, and exact lease release execute after transition locks are released. No application callback or content-bearing closure executes while either ownership lock is held.
- Critical-section test barriers are internal, content-free, non-mutating instrumentation placed before mutation to prove both winners. They are not production/application callbacks and must not re-enter either gate or perform product work; the required critical-section tests and structure audit provide that evidence.

This model preserves bounded lock work: closed enum/reference state, one generation/redirect, one lease reference handoff, and primitive winner results. It introduces no polling, retry loop, unbounded collection, content copy, or network work under a gate.

## Lease Ownership and Release-Branch Audit

The revised plan now defines two complete, non-overlapping release regimes.

### Before an admitted lifetime returns

The exact attempt or its detached cleanup owner retains the lease through completion of the non-cancellable identity or admission operation. Identity read/random/add/reread failure, stale identity completion, discovery failure, phase rejection before core creation, and admission failure without a returned lifetime explicitly invoke exact release once after the operation completes.

Those branches:

- create no terminal coordinator or wait;
- do not release while identity/admission work can still proceed;
- release before clearing a token-current attempt slot or completing the pending public call;
- preserve the prior public state before discovering;
- publish disconnected after the release invocation when discovering already began; and
- permit retry only when Objective-C synchronization actually succeeds.

Defensive handle deinitialization remains a backstop rather than the planned linearization mechanism.

### After successful admission

Atomic attempt-to-session handoff transfers the exact lease into one `SDKPublicTerminalCoordinator`. From acknowledgement onward, only that coordinator can release. It starts the sole lifetime wait before attachment and retains the lease through activation, connected state, public detachment, shutdown, deinitialization, and core terminal.

Terminal-first, transfer-first, shutdown-between-transfer-and-commit, connected-commit-first, deinitialization, stale callback, and delayed waiter/callback orderings all retain one wait and one release gate. Public detachment cannot create a cancellation-to-terminal claim gap. If the wait never completes, the single lease remains held fail-closed without a growing Task family.

The existing low-level limitation remains accurately documented: successful runtime synchronization clears the exact token; claim-exit, release-enter, or release-exit failure may leave ownership unavailable for the process lifetime. No public state, retry, shutdown, or deinitialization promises repair or reacquisition, and stale exact-token release cannot clear a newer owner.

## Retention and Resource Audit

- The permanent core removes strong `NearWire` owner storage and captures App rates by value. Clock, wake, scheduling, drain, and incoming publication operations capture NearWire weakly and return a closed owner-unavailable result after deinitialization.
- No strong path from core, live-operation closures, callback ingress, channel, transition gate, terminal coordinator, wait Task, or wake registration reaches NearWire. A pending instance-method Task legitimately retains NearWire before connect completes; after success, dropping the final App reference releases the hidden handle, requests cancellation, reaches core terminal, and releases through the existing coordinator.
- The coordinator Task retains no pairing code, Bundle metadata, endpoint, certificate, Event, arbitrary internal error, or NearWire actor. Its gate stores only bounded closed state and the first content-free terminal code.
- Pairing ownership ends at admission/discovery handoff. No connected, transition, terminal, cleanup, Keychain, Event, public, diagnostic, logging, or reflection surface retains it. The plan promises reference release rather than secure Swift String zeroization.
- Constant-space network planning remains independent of offline buffer size. The fixed symmetric record maximum, least-privilege downstream capacities, hostile maximum Event/batch/overflow tests, and separate peak-retention accounting remain unchanged from the approved Round 3 contract.
- Identity work remains one bounded-call non-actor worker. Synchronous Security IPC may delay completion, but it cannot block the NearWire actor, start a second worker, or release the lease while stale work can still begin discovery.
- Existing protocol deadlines and active-pump one-shot token/TTL wakes remain the only connection timers. There is no reconnect, background observer, recurring connectivity poll, or retry scheduler.

## Keychain, Redaction, and Transport Recheck

- The read dictionary remains exactly generic-password class, permanent service/account, data-protection Keychain selection, returned data, one match, and `kSecUseAuthenticationUI: kSecUseAuthenticationUISkip`, with no synchronizable, access-group, or authentication-context key.
- The add dictionary remains exactly class, service, account, data-protection selection, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and 36-byte value data. No access control, synchronizable storage, label, comment, caller override, update, overwrite, delete, prompt, retry, sleep, or poll is permitted.
- Stored identity must be canonical lowercase 36-byte RFC 4122 V4 text. Missing storage uses one 16-byte `SecRandomCopyBytes`, explicit V4/variant bits, one add, and at most one duplicate reread. Protected skip → duplicate → protected skip fails closed.
- The modern `kSecUseAuthenticationUISkip` query continues to typecheck without warnings for the supported iOS 16 and macOS 13 targets; deprecated constants and warning suppression remain forbidden.
- Public errors remain fixed and content-safe. Underlying descriptions, Security dictionaries, OSStatus values, pairing/Bonjour data, endpoints, interfaces, certificates, identities, Bundle metadata, Events, protocol values, object identities, and addresses cannot cross the boundary.
- TLS 1.3, fixed ALPN, peer-to-peer-enabled routing, and no plaintext fallback remain unchanged. Documentation explicitly says pairing is not a password, V1 does not authenticate a pretrusted Viewer, an active local impersonator remains in scope, and `viewerIdentityMismatch` is only Bonjour-to-hello consistency.
- Successful connect remains transport and initial-policy activation only, never authenticated Viewer identity, Event receipt, persistence, acknowledgement, or delivery.

## Distribution, Documentation, and Scope Gates

- SwiftPM and CocoaPods must compile the same iOS 16 Swift 5 consumer surface, prove Security.framework linkage, and expose no transition gate, lifetime, coordinator, Keychain, Network, Security, lease, admission, or pump implementation type.
- Host local-network Info.plist declarations remain documented host-App responsibilities. No Keychain-sharing entitlement, third-party dependency, product, target, pod subspec, or privacy declaration is added.
- Required public documentation covers all automatic hello fields, device-only installation-ID correlation and no reset, public pairing semantics, unauthenticated Viewer threat, fixed peer resource exposure, exact state/error behavior, no delivery guarantee, and residual lifecycle scope. A terminology audit rejects authentication overclaims.
- Transition/lease changes are necessary internal composition for one safe public connect. They do not add public disconnect, reconnect, route replacement, lifecycle/background policy, terminal-error history, persistence, UI, logging, analytics, or performance collection.
- Evidence gates require critical-section both-winner tests, pre-admission release branches, one-wait/one-release terminal rows, weak retain graphs, lease-runtime failures, Keychain transcripts, hostile resource boundaries, task/timer inventory, strict concurrency, production TLS, packaging parity, API inventory, entitlement/privacy stability, and independent post-implementation review.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: passed (`Change 'sdk-public-connect' is valid`).
- `git diff --check -- openspec/changes/sdk-public-connect`: passed.
- Xcode warnings-as-errors typecheck of `[kSecUseAuthenticationUI: kSecUseAuthenticationUISkip]` for `arm64-apple-ios16.0-simulator`: passed.
- Xcode warnings-as-errors typecheck of `[kSecUseAuthenticationUI: kSecUseAuthenticationUISkip]` for `arm64-apple-macosx13.0`: passed.
- Static review of the revised proposal, design, tasks, six capability deltas, all prior security findings, current attempt/admission/active ownership and lock graph, process-lease runtime, one-shot termination implementation, weak active-owner operations, Keychain declarations, fixed limit and retention contracts, TLS trust model, package manifest, CocoaPods specification, discovery host declarations, and documentation/evidence gates.

## Unresolved Count

0 findings remain unresolved. Security, privacy, performance, distribution, and documentation planning closure remains granted for pre-implementation Round 4.
