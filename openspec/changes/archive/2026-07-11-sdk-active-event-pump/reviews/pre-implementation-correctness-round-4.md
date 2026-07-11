# Pre-Implementation Correctness and Testing Review — Round 4

## Scope

Re-read the complete current proposal, design, task plan, all seven capability deltas, every Round 3 independent review, and `pre-implementation-remediation-round-3.md`. Re-checked the captured whole-token allowance, nonthrowing bucket commit, owner shutdown before/during/after binding and idle, pause-aware ingress scheduled-latch transitions, deadline races, and all earlier cancellation, policy, queue, rate, TTL, sequence, bounded-work, and deterministic-test findings against the current implementation seams.

Round 3 remediation correctly closes the token-allowance, level-triggered owner-availability, ingress pause/resume, and binding-deadline architecture gaps in the design, task plan, supporting capability deltas, and almost all of the main active-pump capability. One contradictory normative deadline sentence remains.

## Finding

### HIGH — The main binding requirement invalidates the continuous policy deadline when registration succeeds

**Evidence**

- The design requires one initial-policy deadline to start synchronously at runner claim and remain live across both owner binding and initial policy negotiation until activation (`design.md:48-52`). The session-admission delta says the same deadline remains live through binding and policy negotiation (`specs/sdk-session-admission/spec.md:7`), and the active task/timer requirement repeats that only activation cancels it (`specs/sdk-active-event-pump/spec.md:303`).
- The main binding requirement first states that this deadline continuously covers binding plus negotiation, but its next sentence says “registration or activation first SHALL invalidate the exact deadline token” (`specs/sdk-active-event-pump/spec.md:54`). Registration success occurs before the initial offer may arrive, so literal compliance removes the only policy deadline as soon as owner binding completes.
- This conflicts directly with the later scenario requiring a Viewer that never offers policy to terminate with `policyNegotiationTimedOut` (`specs/sdk-active-event-pump/spec.md:311-315`) and with the Round 3 remediation decision that only activation or terminal cleanup invalidates the token (`reviews/pre-implementation-remediation-round-3.md:9-11`).
- Task 4.4 names registration-before-deadline and activation-versus-deadline races, but it does not state the expected registration-first result. An implementation following line 54 could pass a narrowly interpreted registration race test while permanently disabling the negotiation timeout (`tasks.md:22`).

**Impact**

The normative requirements permit two incompatible implementations. One preserves the intended bounded binding-plus-negotiation lifetime; the other cancels the deadline after registration and can retain the channel, core, wake callback, paused activation waiter, and session resources indefinitely when the Viewer never sends an initial policy offer.

**Required remediation**

1. Replace “registration or activation first” with “activation or terminal cleanup first” in the main binding requirement. Registration success must transition from binding to negotiation without replacing, cancelling, or invalidating the existing deadline token.
2. State the registration/deadline race outcomes explicitly: deadline-first closes the operation gate and prevents or cleans exact registration; registration-first may install the exact wake token but the same deadline remains armed and can later terminate negotiation before activation.
3. Expand Task 4.4 so the registration-before-deadline test advances through successful binding but withholds the policy offer, then proves `policyNegotiationTimedOut`, exact wake-token removal, stopped ingress, no activation handle, and no retained deadline or dependency closure. Keep separate activation-first and terminal-first stale-deadline cases.

## Round 3 Findings Verified Closed

- **Captured token allowance:** the core refreshes a bucket copy at the captured selection time, passes a distinct nonnegative whole-token allowance, and the NearWire drain cannot mailbox-commit more live Events than that allowance. A live matching result uses an SPI-only prevalidated nonthrowing subtraction on the exact copy before atomically installing bucket and sequence state. The task plan includes zero/fractional/one/burst cross-products against all other turn bounds and terminal/policy orderings.
- **Owner shutdown:** registration and every schedule refresh/drain distinguish persistent shutdown from a live empty queue. Shutdown-first assigns no callback; assignment-first latches a hint until a level-triggered refresh, including the assignment-result window. Binding, policy negotiation, empty active idle, zero rate, and positive rate have explicit `ownerUnavailable` coverage.
- **Ingress pause/resume:** `running`, `nonterminalPaused`, and `stopped` are lock-linearized separately from the single scheduled latch. A pre-pause callback can park and clear the latch; paused nonterminal input creates no Task; terminal/overflow bypass authorizes one drain; live resume authorizes one retained-input drain; stop suppresses successors. The task matrix covers each latch ordering without sleep or spin.
- **Earlier correctness findings:** activation cancellation and handle transfer, observer and pull/runner precedence, dynamic-policy commit time, committed-prefix versus live result accounting, exact origin-clock TTL, bounded expiry, mailbox lost-wake closure, incoming combined accounting, exact deadline heap, route/sequence validation, terminal gates, task bounds, and no-poll zero-rate behavior remain consistently specified and testable.

## Review Result

One HIGH actionable finding remains. Source apply must remain blocked until the continuous-deadline contradiction and its registration-first deterministic expectation are corrected, followed by another fresh correctness/testing review.

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
git diff --no-index --check /dev/null openspec/changes/sdk-active-event-pump/reviews/pre-implementation-correctness-round-4.md
```

Result: expected no-index difference exit 1 with no whitespace-error output; the new review has no whitespace defect.
