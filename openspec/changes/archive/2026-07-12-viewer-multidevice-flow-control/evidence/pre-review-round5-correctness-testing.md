# Pre-Implementation Correctness and Testing Review — Round 5

Date: 2026-07-13

## Scope

Re-read `AGENTS.md`, every current `viewer-multidevice-flow-control` artifact, all Round 4 reports available for this review chain, and the refreshed validation record. This artifact-only review verified timeout arbitration against retained acceptance frames; partial-tail `needsMoreBytes` handling; detach-before-resume ordering; exact receipt samples, token/continuation ownership, byte accounting, terminal cleanup, and both winner orders; then regressed every earlier lifecycle, identity, policy, sequence, ingress, and workspace finding. No production or test source was modified; this report is the only added file.

## Round 4 Finding Disposition

### Paused suffix ending in a partial frame — Resolved in the ordinary continuation path

The decoder now returns distinct `pausedOnCompleteFrame`, `needsMoreBytes`, and `drained` progress. Only a complete unprocessed frame retains the token and schedules another continuation. A partial tail stays byte-charged, discards its old callback sample for completion decisions, atomically clears continuation state, detaches the old token, and resumes one receive; the completing callback supplies the later sample and may claim one fresh token. Immediate callback reentrancy cannot observe the old token. Resume-first starts at most one generation-matched receive that terminal later cancels, while terminal-first makes resume a no-op. Both terminal orders require zero token, continuation, callback `Data`, and decoder residue (`design.md:116-124`; `spec.md:200-271`; `tasks.md:8,27`).

### Pre-deadline retained acceptance versus timeout — Resolved when the retained suffix contains a complete acceptance

Policy validity now uses the acceptance frame's completion sample. A timeout that overtakes an already-owned suffix sampled before the deadline records `deadlineElapsed`, keeps receive paused, and defers terminal commit while the finite suffix is classified. A matching pre-deadline acceptance commits regardless of timeout/continuation queue order. Equality and later samples remain timeout, while physical terminal, cancellation, and shutdown still invalidate the suffix immediately. Tasks require deadline-minus-one, equality, and deadline-plus-one cases with timeout on both sides of the continuation and exact effective/deadline/close state (`design.md:64-82`; `spec.md:71-128`; `tasks.md:26-27`).

## Finding

### NW-MFC-CT-R5-001 — Medium — `deadlineElapsed` plus `needsMoreBytes` has two contradictory next transitions

**Confidence: 10/10**

The policy arbitration rule says that after timeout records elapsed state, the already-owned finite pre-deadline suffix is classified. If that suffix drains without a matching acceptance, recorded timeout closes exactly once (`design.md:70`; `spec.md:77`). This correctly prevents future bytes from manufacturing a pre-deadline acceptance.

The general decoder rule says that every `needsMoreBytes` result preserves the partial frame, detaches the old continuation/token, and resumes one receive; the later callback completes the frame with its later sample (`design.md:120-122`; `spec.md:206-210`). It contains no exception for `deadlineElapsed` arbitration.

Both rules apply when timeout overtakes a pre-deadline suffix containing complete nonmatching frames followed by a partial next frame. After all complete frames are classified, the suffix has no matching complete acceptance and returns `needsMoreBytes`:

- the policy state machine requires timeout commit, decoder-byte release, token resolution, and no rearm; but
- the decoder state machine requires retaining the partial bytes and rearming one receive.

The partial frame cannot already own a pre-deadline completion sample because it is incomplete. Resuming may later complete it at or after the deadline, but that later input is outside the finite pre-deadline suffix for which timeout deferral was granted. The two implementations therefore differ in receive count, retained bytes, token resolution, close timing, and whether a later callback exists, while both can cite a normative `SHALL`.

Tasks 5.1 and 5.2 cover retained-acceptance timeout arbitration and ordinary partial-tail resume separately, but do not compose elapsed timeout, no complete matching acceptance, and a partial tail. The existing “terminal/timeout-versus-suffix” phrase supplies no exact oracle for this state.

**Required resolution:** make `deadlineElapsed` an explicit higher-priority decoder-owner state. While classifying its owned pre-deadline suffix:

1. `pausedOnCompleteFrame` retains the existing token and schedules the next finite continuation;
2. a matching valid pre-deadline acceptance commits and makes recorded timeout stale;
3. a protocol/policy violation closes with its defined terminal category;
4. `drained` or `needsMoreBytes` without a matching complete acceptance commits the recorded timeout, releases even partial decoder bytes, resolves the token once without rearm, and leaves zero continuation/callback ownership.

Add deterministic tests with timeout queued before and after continuation for a deadline-minus-one callback containing more than one quantum of legal nonmatching frames plus an incomplete acceptance prefix. Assert zero resume/receive count, exact timeout close count/category, unchanged effective policy and sequence for the incomplete frame, released partial-byte count, one token resolution, no continuation, and no later callback. Retain the existing ordinary `needsMoreBytes` resume tests when no elapsed policy timeout exists.

## Prior-Finding Regression Check

- All provisional, negotiating, active, and disconnecting owners remain inside 16 slots; recent rows remain capped at 64 with deterministic eviction, one manager wake, and zero shutdown ownership.
- Exact-tuple duplicate rejection and separate non-inheriting Bundle-ID variants remain coherent and unauthenticated.
- Returning connections still use ordinary negotiating state; no undefined `reconnecting` UI state has returned.
- V1 lower-pair attribution, one pending offer, requested/effective separation, conservative acceptance, and exact deadline boundary remain normative.
- Per-frame receipt samples now consistently govern token, TTL, policy arbitration, throughput, and equal-sample split/coalesced outcomes.
- Secure-channel pause prevents rearm and later-byte overtaking; total input remains bounded by the validated 2 MiB default and 19 MiB hard cap.
- Inbound sequence commits remain whole-frame atomic before local expiry/overflow and after hard/token validation. Downlink sequence, queue, fairness, token, and telemetry commit only with atomic mailbox ownership.
- Physical terminal, cancellation, attachment rollback, decoder failure, and shutdown still clear exact connection-bound queues, decoder bytes, tokens, continuations, and handles without migration or stale-generation revival.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, and 0 Low.**

Both Round 4 findings are resolved on their primary paths. The sole remaining issue is the composed `deadlineElapsed` plus partial-tail transition, which must choose timeout cleanup over ordinary receive resume to make the combined policy/decoder state machine total and testable.
