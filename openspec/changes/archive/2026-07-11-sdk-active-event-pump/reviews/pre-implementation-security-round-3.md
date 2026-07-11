# Pre-Implementation Security, Performance, and Documentation Review — Round 3

Re-read the complete current proposal, design, task plan, six capability deltas, all Round 2 reviews, and the Round 2 remediation note against the existing callback ingress, permanent session core, queue, secure mailbox, public stream, rate, wire, and packaging boundaries. Round 2 remediation closes its previously reported terminal-gate coverage, binding-token lifetime, late run-cancellation, signal-task amplification, and deadline-index growth findings. One newly exposed cross-actor availability issue remains.

## Finding

### HIGH — Binding pause has no ingress-side scheduler handshake, so terminal or retained input can be stranded

**Evidence**

- The revised contract requires `bindingActiveOwner` to stop taking nonterminal ingress batches while the existing bounded callback ingress retains their raw order, yet still requires a later terminal or overflow to preempt binding and successful binding to resume the retained input (`design.md:46-50`; `specs/sdk-active-event-pump/spec.md:52-74`). The artifacts name the pause and resume outcomes but define no lock-level transition for the ingress scheduler latch.
- The existing ingress sets `drainScheduled` before invoking its weak core callback. A later nonterminal or terminal submission does not schedule another callback while that latch is true (`SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:48-59,62-100`). The latch is cleared only by `takeBatch` finding no work or by `finishDrainTurn`; the latter immediately schedules another callback whenever pending work remains (`SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:102-139`).
- The current core drain always takes a batch and then completes it (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:212-232`). During the new binding phase, taking that batch would violate the required raw-input retention. Returning without taking leaves `drainScheduled` set forever; calling `finishDrainTurn` while retained input remains creates a repeated callback loop instead of a parked pause.
- A concrete failing ordering is: nonterminal bytes set `drainScheduled`; the core enters binding before the scheduled drain runs; that drain parks without consuming; then channel terminal or ingress overflow replaces the bounded pending input. Because the latch is still set, no new callback is authorized, so terminal cannot preempt a suspended owner bind. The same lost wake can strand ordinary retained policy/Event bytes after a successful bind. Bounds prevent unlimited memory, but they do not prevent an activation stall, delayed resource release, or avoidable task/power amplification if the implementation tries to repair the problem by repeatedly finishing the drain turn.
- Task 4.4 requests broad binding ingress, terminal, and overflow race coverage, but it does not require the scheduler-latch orderings above or prove that pause/resume is atomic, non-spinning, and exactly-once (`tasks.md:19-22`).

**Required remediation**

Define one explicit pause-aware ingress protocol under the existing ingress lock, or an equivalent fully specified handshake. Entering binding must atomically park nonterminal draining without consuming retained items and without leaving an unusable scheduled latch. Nonterminal submissions while parked must remain bounded and must not create Tasks. Terminal or overflow latching must authorize exactly one terminal-capable drain even while nonterminal draining is parked. Successful live binding must atomically unpark and authorize exactly one drain when retained work exists; terminal cleanup must stop and release everything without a successor. No pause path may call `finishDrainTurn` into a self-rescheduling loop.

Add deterministic barriers for: a drain scheduled before binding but arriving after the pause; terminal and overflow arriving after that drain parks; successful bind with retained policy/Event bytes; terminal racing unpark; stop racing both pause and unpark; and repeated nonterminal submissions while parked. Assert exact raw order, retained count/byte accounting, one terminal result, no lost wake, no post-terminal callback, and a constant bound on routing Tasks. Record this protocol in the design and normative binding requirement rather than relying only on implementation tests.

## Round 2 Findings Verified Closed

- Every expiry, route drop, accepted candidate, wake installation, and incoming publication now has an explicit small shared-gate transaction, with terminal-first mutation prohibition and committed-before-terminal semantics.
- Owner binding now tokenizes wake assignment, returns an atomic initial snapshot, and removes only the exact installed registration.
- Successful activation invalidates run cancellation before waiter resumption and transfers the lifetime handle without a suspension window.
- Outbound notifications now coalesce synchronously before Task creation and retain only a constant-size routing state.
- Incoming deadline indexing is an exact one-node-per-FIFO-item indexed heap with immediate removal, no tombstones, and bounded `O(log n)` mutation.
- Active errors and descriptions remain code-only and exclude route, identifiers, pairing data, endpoints, policy values, queue/Event content, wire bytes, certificates, peer text, underlying errors, and payload-derived diagnostics. No new public product, dependency, entitlement, persistence, Keychain, privacy declaration, or transport-security claim is introduced by this planning change.

## Validation

Command:

```text
DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive
```

Result: PASS — `Change 'sdk-active-event-pump' is valid` (exit 0).

Command:

```text
git diff --check
```

Result: PASS (exit 0). The active OpenSpec change remains untracked as a whole; no production or test source was modified by this review.

## Review Status

One unresolved actionable finding remains. Pre-implementation security/performance/documentation review closure is not granted until the ingress pause/resume scheduler contract is remediated and a fresh independent round reports zero unresolved findings.
