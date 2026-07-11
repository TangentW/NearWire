# Pre-Implementation Correctness and Testing Review — Round 5

## Scope

Re-read the complete current proposal, design, task plan, all seven capability deltas, the three Round 4 independent reports, and `pre-implementation-remediation-round-4.md`. Re-checked the corrected registration-success/no-offer deadline path and every earlier correctness area: cancellation and terminal precedence, policy-consumer ownership, pause/resume scheduled-latch transitions, owner shutdown, dynamic policy boundaries, queue/service/rate accounting, TTL and sequence commitment, mailbox backpressure, incoming retention/publication, bounded work, cleanup, and deterministic test seams.

## Closure Result

Zero unresolved correctness or testing findings remain in the pre-implementation planning artifacts.

### Continuous binding and policy deadline

- Successful runner claim starts one reference-tokenized deadline before owner binding, after the attachment deadline has already been cancelled.
- The corrected main requirement now explicitly retains the same deadline after successful wake registration. Only initial-policy activation or another terminal transition invalidates it (`specs/sdk-active-event-pump/spec.md:54`).
- Registration-first therefore enters policy negotiation with the deadline still armed. If no Viewer offer arrives, the existing timeout scenario terminates once with `policyNegotiationTimedOut` and releases active-pump registration and retained work (`specs/sdk-active-event-pump/spec.md:311-315`).
- Task 4.4 now includes `registration-success-with-no-offer` in addition to deadline-before-registration, registration-before-deadline, terminal-versus-deadline, stale attachment deadline, and activation-versus-deadline barriers (`tasks.md:22`). This closes the Round 4 contradiction without changing the already consistent design, session-admission, timer, cleanup, or error contracts.

### Cancellation, ownership, and terminal races

- Run cancellation and activation have only cancellation-first/no-handle or activation-first/stale-callback outcomes. Handle transfer is synchronous after cancellation-token invalidation.
- The one-shot termination observer has explicit pre-cancelled, stored-terminal, pending terminal-versus-cancellation, second-wait, and non-owning lifetime behavior.
- Pull and active-runner policy ownership is irreversible, with exact second-run, stored-terminal, pre-cancelled, pending/completed pull, and post-claim precedence.
- The shared operation gate separately linearizes wake assignment, every expiry, every route drop, every accepted outbound candidate, and incoming publication. Stale actor results cannot create a third side-effect outcome.

### Ingress binding and owner availability

- Callback ingress mode and the scheduled-drain latch have an implementable lock-level handshake. A pre-pause callback parks and clears its latch; paused nonterminal submissions create no Task; terminal/overflow bypass authorizes one drain; live resume authorizes one retained-input drain; stop wins and suppresses successors.
- Registration and every schedule refresh/drain return persistent owner availability. Shutdown-first assigns no callback; assignment-first persists shutdown before signalling; a signal in the assignment-result window remains token-latched for one level-triggered refresh.
- Owner loss is covered during binding, negotiation, empty idle, zero rate, and positive-rate work without polling or reliance on an unrelated producer signal.

### Queue, token, TTL, sequence, and policy accounting

- The uplink core refreshes one bucket copy at its captured selection time and passes its exact whole-token allowance separately from positive service and byte limits. The NearWire actor cannot commit more live Events than that allowance.
- A live matching result performs the SPI-only nonthrowing prevalidated subtraction on the exact refreshed copy and atomically installs it with the returned sequence counter. Terminal or stale delivery discards only route-local bucket/counter state while preserving any gate-committed mailbox/queue/telemetry prefix.
- Expiry, route drop, acceptance, and rejection consume bounded service units; only offered live candidates consume the byte budget; expiry and route drops consume neither sequence nor rate token. Origin TTL uses the exact NearWire queue clock, while captured core time is restricted to token accounting.
- Dynamic policy transactions wait for old-policy work, encode and prepare both bucket copies at a fresh commit clock before acceptance admission, install nonthrowingly with no intervening Event selection, and remain bounded and ordered.
- Incoming batches validate route, contiguous copied sequence, receiver-local TTL, and complete count/byte capacity atomically. FIFO plus in-flight accounting, exact indexed deadlines, actor-side TTL recheck, terminal-gated publication, and one-token downlink selection remain consistent.

### Bounded work and deterministic evidence

- Queue service, due expiry, incoming publication/expiry, completed frames, deferred policy transactions, callback ingress, decoded retention, secure mailbox, subscriber buffers, deadline nodes, routing Tasks, core Tasks, and decision wakes all have explicit hard or constant bounds.
- Backpressure retains only constant-size candidate/capacity state, re-snapshots after result delivery to close the completion-before-result window, and cannot busy-retry on tokens or producer signals.
- The task plan requires barrier-controlled matrices for token cross-products, owner shutdown, ingress park/resume, deadline orderings, dynamic policy, terminal commit prefixes, TTL/sequence bytes, heap invariants, overflow atomicity, observer/runner cancellation, cleanup, and production-channel integration without sleeps, live Bonjour, or probabilistic scheduling.

## Review Status

Pre-implementation correctness/testing review is closed with zero unresolved findings. This conclusion applies to planning readiness only; implementation tasks, evidence, post-implementation independent reviews, and the final spec-to-evidence audit remain required before archival.

## Validation

```text
DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive
```

Result: PASS (exit 0) — `Change 'sdk-active-event-pump' is valid`.

```text
git diff --check
```

Result: PASS (exit 0, no output). The active change remains untracked, so this command has no tracked diff to inspect.

```text
git diff --no-index --check /dev/null openspec/changes/sdk-active-event-pump/reviews/pre-implementation-correctness-round-5.md
```

Result: expected no-index difference exit 1 with no whitespace-error output; the new review has no whitespace defect.
