# Pre-Implementation Review Round 2 Remediation

## Scope

This note records planning-artifact changes made after the second independent architecture/API, correctness/testing, and security/performance/documentation reviews. It does not claim review closure; a fresh independent round must verify every item.

## Architecture/API Findings

1. **Startup callback binding and ingress ordering** — Added the explicit `bindingActiveOwner` phase. Nonterminal ingress and policy-FIFO consumption pause while the existing bounded raw ingress preserves order. Wake assignment now claims the shared operation gate and atomically returns an initial candidate/deadline snapshot. Terminal-first installs nothing; install-first returns the exact cleanup token.
2. **Ungated expiration and route-drop mutation** — Expanded the shared gate contract to wake assignment, every uplink expiration, every route-affinity drop, every accepted candidate, and incoming publication. Queue scheduling and offering use separate small per-mutation authorization bodies.
3. **Dynamic-policy boundary conflict** — Removed offer observation time as the rate boundary. At commit, the core encodes first, samples a fresh bound-clock time, prepares copies of both buckets without mutation, admits the acceptance, and installs both copies nonthrowingly with no intervening Event selection.
4. **Late run cancellation** — Activation now closes and invalidates the run cancellation gate/token and clears the waiter before resumption. The starter constructs and transfers the handle synchronously without another suspension. The contract permits only cancellation-first/no-handle or activation-first/late-callback-stale outcomes.
5. **Committed prefix versus core-owned accounting** — Narrowed the gate-committed transaction to mailbox, queue, fairness, live-ID, telemetry, and the returned planned sequence prefix. Only a live matching drain result installs the route-local counter and consumes tokens. Terminal cleanup deliberately discards uninstalled route-local counter/bucket state without undoing the committed local-acceptance prefix.
6. **Uplink clock identity** — Removed the core-supplied origin-TTL time. The drain samples the exact `NearWire` instance's injected enqueue clock after actor entry. Core selection time remains separate and is used only for token accounting.

## Correctness/Testing Findings

1. **Wake registration race** — Added terminal-versus-install, prebuffered snapshot, binding input-order, overflow, stale-token, and notification-storm test requirements.
2. **Activation cancellation race** — Added barriers around acceptance, cancellation-gate close, waiter resume, and caller observation, including abandoned completed-task ownership.
3. **Unbounded uplink expiration work** — Replaced “remove every due item” with a positive service quantum. Expiry, route drop, acceptance, and rejection each consume one unit; due-work remainder schedules one immediate coalesced continuation.
4. **Candidate gate versus stale result** — Adopted the split committed-prefix/live-result accounting contract and required deterministic terminal-between-commit-and-result tests.
5. **Observer and runner precedence** — Each termination wait now owns a private cancellation gate with exact one-shot, pre-cancel, stored-terminal, pending, and post-registration ordering. Runner registration now has explicit second-run, stored-terminal, pre-cancel, and policy-ownership precedence with compound test coverage.

## Security/Performance/Documentation Findings

1. **Terminal gating coverage** — The bounded queue delta now normatively requires per-expiry, per-route-drop, and per-accepted-candidate authorization; terminal-first stops later mutation.
2. **Owner binding lifetime** — Binding keeps one bounded actor operation, installs through the shared gate, resumes ingress only for a live matching result, and removes only its exact token.
3. **Run ownership handoff** — Cancellation token invalidation precedes waiter resumption and handle transfer has no suspension window.
4. **Signal-task amplification** — Added `SDKOutboundSignalIngress`, which coalesces under a lock before Task creation and retains at most one weak-routing Task plus one already-authorized dirty successor.
5. **Deadline-index growth** — Specified an exact indexed min-heap with one node per FIFO item, immediate node removal on in-flight transfer, no tombstones or rebuilds, `O(log n)` mutation, maximum node count equal to the FIFO bound, and exact terminal cleanup.

## Validation

`DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive` passed after remediation.

Source apply remains blocked until a fresh review round reports zero unresolved findings in all three dimensions.
