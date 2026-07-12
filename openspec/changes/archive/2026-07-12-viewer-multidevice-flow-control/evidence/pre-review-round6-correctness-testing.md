# Pre-Implementation Correctness and Testing Review — Round 6

Date: 2026-07-13

## Scope

Re-read `AGENTS.md`, every current `viewer-multidevice-flow-control` artifact, the Round 5 correctness report and companion review evidence, and the refreshed validation record. This artifact-only review verified the composed `deadlineElapsed + needsMoreBytes` transition and regressed all lifecycle, identity, policy, receipt-time, decoder/token, sequence, ingress, and workspace requirements and test oracles. No production or test source was modified; this report is the only added file.

## Round 5 Finding Disposition

### `deadlineElapsed + needsMoreBytes` contradictory transition — Resolved

The policy rule now explicitly limits timeout deferral to classification of already-complete frames in the owned pre-deadline suffix. A matching acceptance commits and makes timeout stale. If classification reaches `drained` or `needsMoreBytes` with no matching complete acceptance, recorded timeout closes once, clears partial bytes, resolves the token without rearm, and leaves no continuation. The generic partial-tail resume rule is expressly limited to the ordinary no-timeout path (`design.md:70,120-122`; `spec.md:77,113-117,204-212`). Task 5.2 now distinguishes ordinary partial detach/resume from recorded-timeout partial/drained no-resume cleanup. The combined state therefore has one owner, one transition, one terminal result, and exact byte/token/receive evidence.

## Finding

### NW-MFC-CT-R6-001 — Low — The capacity test plan omits the negotiating state from the normative 16-slot mixture

**Confidence: 10/10**

The normative requirement correctly states that all provisional, negotiating, active, and disconnecting owners share the 16-slot limit. Its scenario requires any mixture of those four states to reject a 17th handoff (`spec.md:3-13`). The design implementation decision agrees (`design.md:30-38`).

Task 5.1, however, asks for “16-slot provisional/active/disconnecting ownership” and omits negotiating (`tasks.md:26`). Task 5.3 requests 16 concurrent sessions and a 17th rejection, but does not require a mixed-state barrier or keep sessions in negotiation while capacity is asserted (`tasks.md:28`). The proposal and design goal summaries also still describe the product limit as negotiating or active sessions rather than all four slot-owning states (`proposal.md:7`; `design.md:13`).

An implementation that releases a provisional slot on attachment but does not count the ensuing 10-second negotiation could pass explicit provisional, active, disconnecting, and fully-active integration cases while violating the normative capacity scenario. Sixteen negotiating peers could then admit a 17th owner and exceed the product-resource bound before any session becomes active.

**Required resolution:** amend task 5.1 to require 16-slot ownership for provisional, negotiating, active, and disconnecting states, including deterministic mixtures and barriers across provisional-to-negotiating, negotiating-to-active, and active-to-disconnecting transitions. Assert exact slot count and 17th rejection before, during, and after each transition, followed by exact release only after cleanup. Update the proposal/design summary wording to describe the same four-state owner bound so the change overview cannot be read as permitting uncounted cleanup or attachment ownership.

## Verified Regression Boundaries

- Recent rows remain separately capped at 64 with deterministic oldest-first eviction, one manager wake, an 80-row maximum snapshot, and zero shutdown ownership.
- Exact-tuple duplicate rejection and distinct non-inheriting Bundle-ID variants remain coherent and explicitly unauthenticated.
- Returning connections use ordinary negotiating state; the undefined `reconnecting` UI state remains absent.
- V1 has one pending offer, conservative lower acceptance, observable no-pending repetition, exact requested/effective separation, and non-resetting 10-second deadlines.
- A retained pre-deadline acceptance commits independent of timeout/continuation queue order; equality/later samples time out, while physical terminal, cancellation, and shutdown remain immediate winners.
- Frame-completion receipt samples govern token, TTL, policy arbitration, throughput, and every receive-time decision. Equal-sample split/coalesced outcomes are invariant; genuinely later samples have only documented later-time effects.
- Decoder progress, secure-channel pause ownership, detach-before-resume, immediate callback reentrancy, stale generation, both terminal orders, total 2/19 MiB input accounting, and zero cleanup residue remain total and test-owned.
- Inbound sequence commits remain atomic for each valid whole frame before local expiry/overflow and after hard/token checks. Downlink sequence, queue removal, fairness, tokens, and telemetry commit only with atomic whole-frame mailbox ownership.
- Workspace state, bounded safe telemetry, content-free diagnostics, persistence exclusions, privacy-manifest evidence, and excluded later-product scope remain intact.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, and 1 Low.**

The composed timeout/partial-tail defect is closed and no new protocol or ownership contradiction was found. One narrow lifecycle-evidence omission remains: negotiating ownership must be named and deterministically exercised in the 16-slot capacity tests before implementation begins.
