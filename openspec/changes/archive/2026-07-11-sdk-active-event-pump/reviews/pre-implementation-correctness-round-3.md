# Pre-Implementation Correctness and Testing Review — Round 3

## Scope

Re-read the complete current proposal, design, task plan, all six capability deltas, every Round 2 independent review, and `pre-implementation-remediation-round-2.md`. Re-checked the remediated contracts against the existing token bucket, queue, `NearWire` shutdown/publication seams, secure mailbox, permanent session core, callback ingress, and deterministic-test requirements. This was a fresh static review; no proposal, design, specification, task, production, or test source was modified by this review.

Round 2 remediation closes the previously reported owner-binding, operation-gate coverage, policy-commit clock, late run-cancellation, committed-prefix, origin-clock, bounded-expiry, signal-amplification, and deadline-index findings. Two newly exposed correctness gaps remain.

## Findings

### HIGH — The uplink drain has no accepted-Event allowance derived from the captured token snapshot

**Evidence**

- The planned NearWire drain accepts route, codec, sequence, service and byte limits, channel, Control reservation, and the operation gate, but no maximum accepted-Event count derived from the uplink bucket (`design.md:90-102`; `specs/sdk-offline-buffer/spec.md:5-9`). Service units bound work; they are not rate permits because expiry, route drop, rejection, and acceptance all consume them.
- The core checks only that whole tokens exist before continuing, then lets the actor perform irreversible mailbox-plus-queue commits, and only after the result returns attempts to consume the complete accepted count at the earlier captured selection time (`design.md:118-126`; `specs/sdk-active-event-pump/spec.md:114-124,150-162`). Nothing currently proves that the accepted count is less than or equal to the whole-token count available at that captured time.
- The existing `EventTokenBucket.consume` rejects a count larger than available whole tokens (`Core/Sources/NearWireFlowControl/EventRateControl.swift:97-120`). For example, with one token, 64 eligible queued Events, and sufficient mailbox/service/byte capacity, the current contract permits the NearWire drain to commit multiple Events before the core attempts an invalid multi-token consumption. Those mailbox, queue, fairness, telemetry, and sequence-prefix effects cannot be rolled back.
- Tasks 3.2, 5.1, and 5.2 describe service/byte limits and post-result token consumption but do not require a captured whole-token allowance to constrain actor acceptance. Task 5.3 requests broad burst/refill coverage but no matrix proving `accepted <= capturedWholeTokens` when the other turn limits are larger (`tasks.md:14,26-28`).

**Impact**

The implementation can exceed the negotiated uplink rate and then either fail during token consumption after peer-visible admission or invent a special post-commit accounting path absent from the plan. This breaks the claimed exact token, sequence, and terminal-prefix semantics.

**Required remediation**

1. At the core selection time, refresh a bucket copy and obtain the exact whole-token allowance before launching the drain. Pass that allowance as an explicit maximum accepted-Event count distinct from the service and byte limits.
2. Require the NearWire drain to commit no more business Events than that allowance. Expiry and route-drop maintenance may remain token-free but must still consume service units; once no permit remains, the result must expose remaining eligible work without offering another live Event.
3. For a live matching result, install the returned sequence counter and consume the accepted count from the already validated captured-time bucket state through a nonfailing/prevalidated commit. Terminal or stale delivery must retain the existing discard semantics.
4. Add a deterministic cross-product matrix covering zero, fractional, one, and burst token availability against smaller/equal/larger service, byte, queue-depth, and mailbox bounds; include route drops and expiries before live candidates, byte-shortened prefixes, backpressure, dynamic policy deferral, and terminal between candidate commit and result. Assert mailbox frames, queue IDs, sequence prefix, token snapshot, telemetry, next wake, and that token consumption cannot fail after an accepted prefix.

### HIGH — Owner shutdown is not represented in wake registration or refresh results, leaving a startup and idle lost-wake path

**Evidence**

- The binding transaction returns only an initial fair-candidate/deadline snapshot (`design.md:68-72`; `specs/sdk-offline-buffer/spec.md:34-43`). The outbound schedule refresh/drain dependencies likewise describe queue selection, deadlines, and work results, not a persistent owner-availability result (`design.md:120-126,150-154`; `specs/bounded-event-queue/spec.md:3-13`).
- The callback contract says shutdown notifies the active owner so it can terminate (`design.md:70`; `specs/sdk-offline-buffer/spec.md:38`; `specs/sdk-active-event-pump/spec.md:152`), but a shutdown that completes before callback assignment has no historical notification. A shutdown racing or following assignment produces only the same coalesced work signal as an ordinary queue mutation; the specified initial/refresh result gives the core no required way to distinguish permanent owner loss from an empty queue.
- This matters even with no queued work: the current `NearWire.shutdown()` persistently changes owner state and clears the queue (`SDK/Sources/NearWire/NearWire.swift:231-239`). Existing empty outbound drain behavior also demonstrates why an empty result alone cannot prove owner availability (`SDK/Sources/NearWire/NearWire.swift:471-485`). A shutdown-before-registration pump, or a shutdown signal during policy negotiation/zero-rate idle, can therefore wait for an unrelated Event, report the wrong policy timeout, or remain active indefinitely instead of terminating with the specified `ownerUnavailable` code.
- The deterministic plan covers terminal-versus-registration, stale registration, queue notifications, binding ingress/overflow, and downlink owner-unavailable implementation, but it does not require shutdown-before/during/after-registration or an empty/zero-rate owner-loss matrix (`tasks.md:13-15,20-22,26-35`).

**Impact**

Owner lifetime is not level-triggered across binding. A valid permanent shutdown can be lost before callback registration or reduced to an indistinguishable edge afterward, violating the promise that shutdown terminates the active owner and potentially leaving an idle core, wake registration, channel, and handle alive indefinitely.

**Required remediation**

1. Make owner availability part of the gate-authorized registration result and every bounded schedule refresh/drain result, or give the callback a closed reason that is latched before registration. An empty live queue and a shutdown owner must be distinct outcomes.
2. Define exact actor ordering: shutdown-first rejects/returns the binding result as `ownerUnavailable` without installing a callback; install-first returns its token, after which shutdown emits one observable terminal owner result and exact-token cleanup follows. A generic signal must be followed by a level-triggered availability read so coalescing cannot lose shutdown.
3. Require owner loss during `bindingActiveOwner`, initial policy negotiation, active positive/zero uplink rate, and completely empty bidirectional work to terminate once with `ownerUnavailable`, subject only to an already-won core terminal cause.
4. Add barrier-controlled tests for shutdown before registration, between gate claim and assignment return, after assignment but before core result delivery, during policy negotiation, and during empty/zero-rate active idle. Assert registration token cleanup, no policy timeout substitution, no recurring wake, exact terminal precedence, at-most-once channel cancellation, and no retained callback/task/dependency closure.

## Round 2 Findings Verified Closed

- `bindingActiveOwner` plus gate-authorized assignment and an atomic initial queue snapshot closes removal-before-install and initial wire-order races for a live owner.
- Every wake assignment, expiry, route drop, accepted candidate, and incoming publication now has an explicit small operation-gate boundary; committed-prefix and live core accounting are intentionally separated.
- Activation invalidates the run cancellation token before waiter resumption and synchronous handle transfer; observer and runner/pull precedence now have exact gates and compound test requirements.
- Dynamic policy transactions prepare both bucket copies at a fresh commit clock before acceptance admission, then install them nonthrowingly without Event selection between ordered transactions.
- Uplink TTL uses the exact NearWire origin clock, expiry work has a positive service quantum, signal ingress coalesces before Task creation, and downlink uses an exact one-node-per-FIFO-item indexed deadline heap.

## Review Result

Two HIGH actionable findings remain. Source apply must remain blocked until the planning artifacts define a captured-token acceptance allowance and level-triggered NearWire owner availability, add the deterministic matrices above, and a fresh correctness/testing review reports zero unresolved findings.

## Validation

```text
DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive
```

Result: PASS (exit 0) — `Change 'sdk-active-event-pump' is valid`.

```text
git diff --check
```

Result: PASS (exit 0, no output). The active change is currently untracked, so this command has no tracked diff to inspect.

```text
git diff --no-index --check /dev/null openspec/changes/sdk-active-event-pump/reviews/pre-implementation-correctness-round-3.md
```

Result: the expected no-index difference exit 1 with no whitespace-error output; the newly added report has no whitespace defect.
