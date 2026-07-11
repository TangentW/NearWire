# Pre-Implementation Architecture and API Review — Round 5

Re-read the complete current proposal, design, task plan, all seven capability deltas, the Round 4 architecture report, and `pre-implementation-remediation-round-4.md`. Re-audited every architecture/API finding from Rounds 1 through 4 against the current permanent session core, callback ingress, NearWire actor lifecycle, Core/SDK module graph, queue, rate, mailbox, timer, ownership, and supported API contracts.

## Findings

ZERO unresolved architecture/API findings.

## Round 4 Closure Verified

- The active-owner binding requirement now states one unambiguous lifetime: runner claim starts the reference-tokenized initial-policy deadline before any actor suspension; successful wake registration retains that same token; only activation or another terminal transition invalidates it (`specs/sdk-active-event-pump/spec.md:52-58`).
- The same token therefore remains live after registration while buffered policy is consumed and while the core waits for a future initial offer. The existing Viewer-never-offers scenario requires `policyNegotiationTimedOut`, and Task 4.4 now explicitly includes `registration-success-with-no-offer` together with registration/deadline, terminal/deadline, stale-token, and activation/deadline orderings (`specs/sdk-active-event-pump/spec.md:311-315`; `tasks.md:19-22`).
- This matches the design, session-admission delta, timer ownership requirement, and Round 4 remediation note. No attachment deadline is incorrectly revived or replaced: attachment already cancelled it, and runner claim creates the new continuous binding-plus-policy deadline.

## Earlier Architecture/API Closure Audit

- **Cross-actor terminal linearization:** wake assignment, each expiry, each route drop, each accepted outbound candidate, and incoming publication use the shared operation gate at their irreversible boundaries. Terminal-first mutates nothing; operation-first has explicit committed-before-terminal semantics.
- **Binding and ingress:** `bindingActiveOwner` starts only after validation and runner claim. The lock-linearized `running`/`nonterminalPaused`/`stopped` ingress mode is implementable beside the current single `drainScheduled` latch, including scheduled-callback parking, terminal/overflow bypass, exact resume authorization, stop precedence, and no paused self-reschedule.
- **Policy atomicity and run ownership:** complete bidirectional policy transactions wait for captured-time old-policy work, prepare both bucket copies at a fresh commit clock before mailbox admission, and install without suspension. Activation closes the run cancellation gate and invalidates its token before waiter resumption and synchronous lifetime-handle transfer.
- **Uplink accounting and clock identity:** the drain receives a captured whole-token allowance separate from service and byte limits, cannot accept a larger live prefix, and a live result uses the repository-only cross-target prevalidated bucket commit on the exact refreshed copy. Origin TTL is sampled from the exact NearWire instance clock after actor entry.
- **Owner lifetime and scheduling:** registration and every refresh/drain distinguish persistent shutdown from an empty live queue. Shutdown-first rejects assignment; assignment-first persists unavailable state before signalling; pre-result signals remain binding-token-latched. Token-or-TTL wakes are one-shot, zero-rate expiry remains live, and bounded continuation quanta prevent recurring polling or unbounded turns.
- **Queue, sequence, and backpressure:** queue ownership remains inside NearWire; rejected and unattempted candidates retain identity, TTL, ordinal, fairness, and sequence; accepted prefixes commit only with reserved mailbox admission; completion-before-result and candidate-identity checks close backpressure lost wakes without retaining encoded payloads.
- **Downlink bounds and lifetime:** complete route/sequence/batch validation precedes retention, FIFO plus charged in-flight accounting is exact, the indexed deadline heap has one node per queued item, publication rechecks TTL at the actor boundary, and the shared gate orders publication against terminal cleanup.
- **API and packaging boundary:** the starter, handle, errors, dependencies, token commit, queue/drain seams, and ownership types remain repository-internal or Core SPI. SwiftPM already gives NearWire a direct NearWireFlowControl dependency; CocoaPods compiles Core and SDK through the established SPI-hidden module. No supported signature, product, target, subspec, runtime dependency, entitlement, privacy declaration, lease, state publication, lifecycle observer, persistence, UI, or performance collection is added.

## Review Status

Pre-implementation architecture/API review closure is granted for the current planning artifacts. This report does not mark Task 1.2 complete by itself; correctness/testing and security/performance/documentation must independently report zero unresolved findings in the same fresh round before source apply begins.

## Validation

`DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive` passed with `Change 'sdk-active-event-pump' is valid` (exit 0).

`git diff --check -- openspec/changes/sdk-active-event-pump/reviews/pre-implementation-architecture-round-5.md` passed with no output (exit 0). The active OpenSpec change remains untracked as a whole; this review modified no proposal, design, specification, task, production, or test source.
