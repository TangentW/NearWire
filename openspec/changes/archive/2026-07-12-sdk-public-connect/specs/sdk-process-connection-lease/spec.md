## MODIFIED Requirements

### Requirement: Lease work starts only through explicit connection ownership

NearWire construction and ordinary Event, stream, diagnostics, clearing, and state operations SHALL NOT claim or release the process lease. A valid connect SHALL reserve exact instance ownership before synchronous claim. Only successful claim MAY proceed to Keychain, discovery, admission, or pumping. Same-instance overlap SHALL fail before claim; another instance or independently loaded image SHALL receive contention and SHALL NOT reuse or preempt the owner.

The public attempt SHALL retain its exact handle until its non-cancellable worker or admission completes. Without a lifetime, ordinary or Task-cancelled cleanup SHALL release once before clearing the still-attached slot and completing the call. Shutdown MAY detach the slot immediately; its non-public cleanup owner SHALL release after operation completion, mutate no later actor state, and only then complete the pending call. Immediately after successful admission, one same-transition-gate atomic handoff SHALL transfer the handle into exactly one terminal coordinator and acknowledge it before the attempt clears ownership. Cancellation or shutdown racing handoff SHALL leave one owner. The coordinator SHALL start one lifetime wait and retain the lease through attachment, activation, public detachment, shutdown, deinitialization, and core terminal. Only it SHALL release after terminal.

Successful synchronization SHALL clear the exact token and permit later claim. Failed claim exit, release enter, or release exit remains fail-closed and MAY leave ownership unavailable for process lifetime. No public state promises successful release or reacquisition after runtime failure, and no supported lease/reset API is exposed.

#### Scenario: First public attempt claims ownership

- **WHEN** one valid idle instance calls connect while the registry is available
- **THEN** its exact attempt owns the lease before Keychain, discovery, or network work

#### Scenario: Cancellation precedes terminal state

- **WHEN** public ownership detaches and requests cancellation while the prior internal owner can still operate
- **THEN** cleanup retains the exact lease and a competitor still receives contention

#### Scenario: Admission never returns a lifetime

- **WHEN** identity, discovery, phase authorization, or admission fails after claim
- **THEN** the attempt invokes exact release after that operation completes and starts no terminal wait

#### Scenario: Terminal cleanup releases ownership

- **WHEN** the prior internal owner is terminal and runtime synchronization succeeds
- **THEN** exact release permits later acquisition

#### Scenario: Runtime cleanup fails

- **WHEN** exact release enter or exit fails
- **THEN** no wrong token is cleared and later acquisition is not promised
