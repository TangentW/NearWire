# Pre-Implementation Architecture and API Review — Round 5

## Scope

Final narrow confirmation of the two Round 4 findings against the revised design, capability deltas, tasks, and current admission/core ownership boundaries. This round checks planning blockers only; implementation correctness, retention, and race evidence remain required by the apply and post-implementation review gates.

## Round 4 Resolution

### 1. Cross-admission cancellation/terminal chronology — Resolved

One `SDKSessionTransitionGate` is now created before the public attempt can suspend and is passed by reference identity through admission into `SDKSessionLifetime` (`design.md:58-69,117-129`; `specs/sdk-session-admission/spec.md:5-11,33-36`; `specs/sdk-public-connect/spec.md:86-110`; `tasks.md:18,23`). Task cancellation, target generations, phase authorization, core terminal marking, active transfer, connected commit, and lease handoff therefore use one chronology. Delayed admission-result delivery no longer requires copying between gates and cannot reverse Task-cancellation versus terminal order.

The same gate still preserves the previously approved terminal protocol: the core synchronously marks terminal before waiter resumption, transfer and connected commit claim the same lock, and a successful connected claim is followed by owner installation, connected publication, and return in one no-suspension actor turn. The asynchronous waiter remains only the lease-release and weak-callback mechanism, not the winner authority.

### 2. No-lifetime cleanup and shutdown detachment — Resolved

The artifacts now define two non-overlapping regimes (`design.md:149-159`; `specs/sdk-public-connect/spec.md:149-168`; `specs/sdk-process-connection-lease/spec.md:5-24`; `tasks.md:26`):

- Ordinary failure and Task cancellation keep the public slot attached until the operation completes, release is invoked once, the slot is cleared, state is updated when applicable, and the pending call completes.
- Shutdown alone detaches the public slot immediately. A non-public cleanup owner retains the attempt and lease, completes the operation, releases once, performs no later actor mutation, and only then lets the pending call return `shutdown`.
- A returned lifetime transfers the lease atomically to the sole terminal coordinator, which releases only after its one waiter observes the synchronous core terminal mark.

The former “every path releases after terminal” wording is gone. No-lifetime branches now release after operation completion, while lifetime branches release after terminal observation. This is consistent with immediate final shutdown and fail-closed lease semantics.

## Blocking Architecture/API Findings

None. The public surface remains limited to `connect(code:)`, safe pre-return errors, and existing state observation. Internal gate, lifetime, coordinator, lease, Network, and Security types remain hidden, and lifecycle policy remains roadmap item 13.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Static consistency check of the revised transition identity, core terminal mark, same-turn actor commit, cancellation/shutdown precedence, lease handoff, no-lifetime cleanup regimes, and prior architecture findings: PASS.

## Unresolved Count

**0 unresolved findings. Architecture/API planning approval is granted.**
