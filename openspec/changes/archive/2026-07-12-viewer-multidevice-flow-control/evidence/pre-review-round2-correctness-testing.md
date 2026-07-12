# Pre-Implementation Correctness and Testing Review — Round 2

Date: 2026-07-13

## Scope

Re-read `AGENTS.md`, the complete current `viewer-multidevice-flow-control` proposal, design, capability specification, task plan, change metadata, README, pre-implementation validation evidence, and all three round-one review reports. This artifact-only review verified the round-one correctness remediations for lifecycle totality, recent-row/session/wake bounds, monotonic policy winner rules, and inbound/downlink sequence commit semantics. It also checked the revised artifacts for new state-machine and test-oracle contradictions. No production or test source was modified; this report is the only added file.

## Round-One Finding Disposition

### 1. Recent-row bounds and logical-route lifecycle — Resolved

The revised artifacts cap owned sessions at 16 and recent rows separately at 64, define deterministic oldest-disconnect-time eviction with correlation-key tie-breaking, and assign all recent-row expiry work to one manager-owned replaceable wake (`design.md:42-60`; `spec.md:39-63`). The lifecycle table now covers absent/recent admission, provisional rollback, duplicate rejection, negotiation, terminal cleanup, recent-row expiry, and manager shutdown. A live slot remains occupied through disconnecting and is released only after exact handle cleanup. Tasks 5.1 and 5.3 require injected monotonic time, barriers, multi-wave churn, exact 30-second boundary behavior, deterministic eviction, one expiry owner, and zero retained shutdown ownership.

### 2. Initial and dynamic policy timing and winners — Resolved

Both initial and dynamic offers now use injected, non-resetting 10-second monotonic deadlines that begin immediately before encoding and atomic mailbox admission (`design.md:62-80`; `spec.md:65-103`). Local admission time is included, send completion is excluded, and admission failure closes immediately. The core serial queue and sampled monotonic time select the winner: acceptance requires `now < deadline`, equality is timeout, acceptance-first commits once, and timeout/terminal/shutdown-first prevents effective-state mutation and later offers. A valid acceptance commits only the current conservative offer result before any latest desired edit is offered. Task 5.1 requires both winner orders, exact requested/effective state, exact close count, barriers, and injected monotonic time.

### 3. Inbound and downlink sequence commit semantics — Resolved

Inbound processing now validates a whole frame and safe receiver-local deadlines before atomically committing its contiguous sequence range; local expiry and queue-overflow outcomes occur after that commit, while malformed, wrong-route, noncontiguous, deadline-overflowing, ingress-contract-violating, or work-limit-violating frames commit none (`design.md:94-110`; `spec.md:128-175`). Downlink sequences remain tentative until one complete encoded frame is atomically admitted to the secure mailbox. Rejection commits no sequence, queue removal, fairness credit, rate token, or telemetry, while an earlier successfully admitted whole frame remains committed and no frame can have a partial prefix. Task 5.2 requires the combined TTL/overflow/route/admission cases and exact queue, token, fairness, sequence, and retry state.

## Finding

### NW-MFC-CT-R2-001 — Low — `reconnecting` remains a required presentation state without a lifecycle definition or deterministic test oracle

**Confidence: 10/10**

The remediated lifecycle intentionally removed live replacement candidates. Its complete state table now contains absent/recent, provisional, negotiating, active, disconnecting, and shutdown behavior; a successful handoff for a recent key removes the exact recent row and enters `negotiating` (`design.md:50-58`). The normative correlation requirement similarly defines a recent row followed by a fresh unauthenticated connection, without a `reconnecting` state (`spec.md:39-63`).

However, both the design and the normative workspace requirement still say that the sidebar lists `reconnecting` rows (`design.md:124-128`; `spec.md:234-238`). Neither artifact defines whether that label belongs to the old recent row, the provisional handoff, a negotiating connection that happened to replace a recent row, or some time-bounded presentation flag. Task 5.4 requests presentation tests but supplies no entry, exit, failure, expiry, or shutdown oracle for this state.

Two implementations could therefore satisfy the lifecycle rules while rendering incompatible UI state: one could transition directly from recently disconnected to negotiating, while another could retain `reconnecting` through attachment or policy acceptance. Failure and expiry races could also leave a presentation-only flag with no specified generation owner.

**Required resolution:** either remove `reconnecting` from the workspace state list because a returning connection immediately enters the already-defined provisional/negotiating lifecycle, or define it explicitly as a presentation-only projection with exact entry, exit, failed-attachment, expiry-boundary, terminal, generation, and shutdown rules. Amend task 5.4 with deterministic assertions for the chosen behavior.

## Verified Strengths

- The 16 live-slot, 64 recent-row, one manager expiry-wake, and latest-only bounded snapshot limits compose into a finite manager model.
- Duplicate live claims are rejected in every admission mode, and downlink work never migrates by unauthenticated correlation key.
- Policy deadlines and terminal winners are monotonic, non-resetting, serial, and observable without sleep-based tests.
- Inbound expiry/overflow and downlink mailbox-rejection paths now have unambiguous sequence ownership and exact state assertions.
- Work-limit and sender-contract rejection happen before inbound sequence commit, while local expiry and priority overflow happen after commit.
- The revised tasks require proportionate unit, concurrency, integration, presentation, packaging, privacy, and spec-to-evidence coverage without adding another harness.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, and 1 Low.**

All three round-one correctness/testing findings are resolved. The sole remaining issue is a small but normative state-model mismatch introduced by the lifecycle simplification; it must be resolved so implementation and presentation tests share one deterministic device-state oracle.
