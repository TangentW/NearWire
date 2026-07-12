# Pre-Implementation Correctness and Testing Review — Round 2

Date: 2026-07-12

## Scope

Independently re-reviewed the complete active `viewer-application-foundation` proposal, design, capability specifications, task plan, and pre-implementation validation evidence after remediation of the first correctness/testing review. This round specifically traced admission capacity and deadline ownership, all policy/pause/replacement/shutdown transitions, their terminal races, deterministic test obligations, and the later-change boundary. No production, test, specification, task, evidence, or other documentation file was modified by this review.

## Findings

No actionable correctness or testing findings remain.

## Remediation Verification

### Runtime-wide admission bound and deadline

The artifacts now define one runtime-wide capacity of exactly 32 slots shared by current and replacement listener generations. A slot is reserved before wrapper claim or per-connection work, remains held across TLS/channel readiness, partial or complete pre-Hello decoding, optional approval, and consumer handoff, and is released exactly once on handoff or cancellation. The 33rd arrival is cancelled without a channel, decoder Task, deadline Task, or UI row. This closes the former gap in which silent or partial-Hello peers could consume unbounded work outside the confirmation limit.

Every claimed attempt now has one monotonic 10-second claim-to-terminal deadline in both automatic and confirmation modes. Completing App Hello or entering pending approval cannot reset or extend it. One terminal gate selects handoff or cancellation exactly once, so timeout racing Accept, Reject, Pause, replacement commit, shutdown, or a channel terminal event cannot double-complete or double-release the slot.

### Total transition policy

The design's transition table and matching normative capability text assign coherent outcomes for all relevant states:

- approval policy is sampled when a complete valid Hello reaches the decision point, and an existing pending row retains its original policy decision;
- Pause cancels claimed/pre-Hello and pending attempts, Resume affects only future arrivals, and handed-off ownership is preserved;
- replacement preparation retains the old registered listener and its attempts, replacement failure preserves them, and replacement commit cancels only old-generation attempts that have not handed off;
- shutdown cancels all non-handed-off attempts and asks the handoff consumer to close owned sessions; and
- deadline, Accept, Reject, Pause, replacement commit, and shutdown converge through the same exact terminal gate.

These rules remove the previously plausible but conflicting implementation choices for in-flight and pending attempts.

## Coverage and Determinism Assessment

Task 5.1 now requires deterministic coverage for silent and partial peers under both approval policies, the exact shared-generation 32/33 boundary, the single non-resetting 10-second deadline, slot release, policy snapshots, Pause, replacement commit and failure, stale callbacks, and shutdown cleanup. Together with the permanent connection owner, generation token, continuous decoder, and exact terminal gate required by task 4.3, these tests can order races under controlled clocks/gates without wall-clock sleeps or live Bonjour dependency.

The remaining identity, listener, presentation, packaging, and repository gates are still proportionate to the change. The plan does not add a parallel mutation framework, source-text conformance harness, or brittle pixel assertions.

## Deferral Assessment

The boundary remains coherent: this change owns identity, publication, bounded Hello admission, optional approval, and one opaque same-core handoff. Its placeholder consumer closes accepted handoffs cleanly. Hello acknowledgement, flow policy, active multi-device sessions, Event transfer, storage, explorer UI, controls, and performance views remain explicitly assigned to later changes without requiring callback or decoder ownership to move.

## Validation

- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS** (`Change 'viewer-application-foundation' is valid`).
- `DO_NOT_TRACK=1 openspec status --change viewer-application-foundation`: **PASS** (4/4 artifacts complete).
- `git diff --check`: **PASS**.

## Verdict

**Pre-implementation correctness/testing approved. Exact unresolved actionable finding count: 0.**
