# Pre-Implementation Review Round 3 Remediation

## Scope

This note records planning changes made after the third independent review round. It does not grant closure. Source apply remains blocked until a fresh round reports zero unresolved findings in architecture/API, correctness/testing, and security/performance/documentation.

## Findings and Remediation

### Continuous deadline across binding

Pump attachment already cancels the attachment deadline. Successful runner claim now synchronously starts one new reference-tokenized initial-policy deadline before any owner actor suspension. The same deadline covers `bindingActiveOwner` and initial policy negotiation until activation. Deadline-first terminates with `policyNegotiationTimedOut`; activation or terminal cleanup invalidates the token; stale delivery does nothing. Deterministic tasks now cover deadline-before-registration, registration-before-deadline, terminal versus deadline, stale attachment-deadline delivery, and activation versus deadline.

### Pause-aware callback-ingress handshake

The session ingress now has a normative lock-level `running`, `nonterminalPaused`, and `stopped` mode in addition to its single scheduled-drain latch. A callback delivered after pause may take terminal/overflow but otherwise clears the latch and parks without consuming input or scheduling a successor. Paused nonterminal submissions remain bounded and create no routing Task. Terminal/overflow bypasses pause with exactly one drain. A live binding result atomically resumes and authorizes one drain for retained work; stop suppresses every successor. `finishDrainTurn` may not self-reschedule parked nonterminal input. Tasks enumerate pre-pause callback delivery, terminal/overflow after park, repeated parked submissions, live resume, terminal/stop versus resume, exact accounting, no lost wake, and no spin.

### Captured token allowance before irreversible uplink work

At selection time the core now refreshes a value copy of the uplink bucket and captures its exact whole-token allowance. The NearWire drain accepts that nonnegative allowance separately from positive service and byte limits and commits no more live Events than allowed. Expiry and route-drop maintenance may remain token-free within the service quantum. A live result uses an internal SPI-only nonthrowing prevalidated subtraction on the exact refreshed copy, then atomically installs the bucket and returned counter. A new `event-rate-control` delta and cross-product test tasks cover zero, fractional, one, and burst allowances against queue, service, byte, mailbox, maintenance, policy, backpressure, and terminal orderings.

### Level-triggered NearWire owner availability

Wake registration and every schedule-refresh/drain result now distinguish persistent owner shutdown from a live empty queue. Shutdown-first returns unavailable without callback assignment. Assignment-first persists shutdown before emitting a coalesced hint; every hint is followed by an availability read. A signal delivered before the binding result remains token-latched and forces one refresh after live binding, closing the assignment-result race. Owner loss during binding, policy negotiation, empty active idle, and zero/positive-rate work terminates once with `ownerUnavailable`, subject to a previously won core terminal cause. Tasks cover shutdown before, during, and after registration and exact cleanup.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive` passed.
- `DO_NOT_TRACK=1 openspec validate --all --strict --no-interactive` passed: 23 items, 0 failures.
- `git diff --check` passed.

No production or test source was modified during remediation.
