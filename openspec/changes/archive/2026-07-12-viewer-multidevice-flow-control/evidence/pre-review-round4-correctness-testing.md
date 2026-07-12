# Pre-Implementation Correctness and Testing Review — Round 4

Date: 2026-07-13

## Scope

Re-read `AGENTS.md`, every current `viewer-multidevice-flow-control` artifact, and all Round 3 review reports after the latest remediation. This artifact-only review checked frame-completion receipt-time semantics; the internal `SecureByteChannel` pause-token and decoder-continuation state transitions; retained-input bounds; ordering, exactly-once cleanup, terminal races, and test oracles; and regression of all earlier lifecycle, identity, policy, sequence, ingress, and workspace fixes. No production or test source was modified; this report is the only added file.

## Round 3 Finding Disposition

### Frame receipt-time ambiguity — Substantially resolved

Every receive callback now captures an injected monotonic sample, and each complete frame uses the sample of the callback whose bytes complete it. A frame completed before a decoder pause retains that sample across continuation turns; a fragmented frame uses the later callback that completes it. The same sample governs sender/system buckets, receiver-local TTL origin, policy-deadline comparison, throughput, and every other receive-time decision. Split/coalesced equivalence is correctly limited to equal per-frame samples, while genuinely later split samples may cause their documented time-based result (`design.md:119`; `spec.md:195`). Finding 2 below concerns the remaining conflict between this arrival-time rule and the older timeout-winner rule, not the frame-sample definition itself.

### Decoder-only pause and eager channel rearm — Substantially resolved

The artifacts now authorize a narrow internal, generation-bound secure-channel receive-pause token. It can be claimed only during synchronous `.received` delivery, prevents driver rearm, is retained with one decoder suffix and one same-executor continuation, and resolves once by resume or terminal invalidation. Consumers that do not claim it keep the existing eager loop. Total connection input now includes decoder partial/pending bytes plus transient callback `Data`, uses a 2 MiB default and 19 MiB hard cap, and requires overflow-safe cross-limit validation (`design.md:111-119`; `spec.md:187-195`; `tasks.md:8,27`). The immediate-completion and stale-generation tests provide the right lower-layer seam. Finding 1 below concerns one omitted continuation state inside that model.

## Findings

### NW-MFC-CT-R4-001 — Medium — A paused suffix ending in an incomplete frame has no progress transition

**Confidence: 10/10**

The token is required to resume only after the retained suffix “drains,” and no next receive or callback may exist while the token is held (`design.md:115-117`; `spec.md:191-193`). However, the total-input model explicitly allows decoder partial-frame bytes, and ordinary stream delivery permits a callback to contain more complete frames than one service quantum followed by the prefix of another frame (`design.md:111`; `spec.md:187`).

After continuations consume every retained complete frame, that trailing prefix remains in the decoder. It cannot become a complete frame until another receive occurs, but another receive cannot start until the token resumes. If “suffix drains” means zero decoder bytes, the session deadlocks permanently. If it means no currently complete/serviceable frame remains, the core must resume while retaining a charged partial frame, but that transition, its byte accounting, token ownership order, and sample assignment are not stated.

Task 5.2 separately asks for pause/resume and partial-frame completion under a later sample, but it does not combine them. It therefore does not prove the critical path of a quantum-exceeding callback ending with a partial next frame. The immediate driver-completion test also lacks the required reentrant ordering: the old token and continuation must be detached before resume can synchronously deliver bytes that complete the partial frame and potentially claim a new token.

**Required resolution:**

1. Define suffix service completion as “no complete frame remains for the current receipt sample,” not necessarily zero decoder bytes.
2. When that state is reached, atomically detach/consume the old continuation and token on the core executor before invoking resume exactly once. Keep any bounded partial-frame bytes in the decoder and charged to the 19 MiB total budget.
3. Permit the resumed callback to complete that partial frame with its new callback sample and, if it again exceeds a quantum, claim a fresh generation-valid token without observing the old token.
4. Specify both serialized terminal winner orders around detach/resume: terminal-first invalidates without rearm; resume-first starts at most one receive, after which terminal cancels that generation normally.
5. Extend task 5.2 with a callback containing one full service quantum plus at least one complete frame and a trailing frame prefix, multiple continuation turns, exact retained-byte counts, exactly one old-token resolution, synchronous next completion, the later completion sample, optional fresh-token claim, and zero residue after terminal/shutdown.

### NW-MFC-CT-R4-002 — Medium — Pre-deadline frame receipt and timeout-first terminal ordering still define conflicting policy winners

**Confidence: 10/10**

The new rule says a frame's completion sample governs policy-deadline comparison and continuation delay cannot change any receive-time decision (`design.md:119`; `spec.md:195`). The existing policy state machine instead says acceptance is valid when processed with `now < deadline`, and the core executor chooses one acceptance/timeout winner; timeout processed first closes and prevents later mutation (`design.md:64-81`; `spec.md:71-109`).

These rules conflict when an acceptance frame is completed before the deadline but remains behind a service-quantum pause until after a timeout callback is enqueued. Under the receipt-time rule, the acceptance is before deadline and continuation delay must not alter it. Under the timeout-first rule, the timeout closes before the continuation processes that acceptance. Callback grouping can expose the conflict: the same acceptance with the same injected sample may commit when delivered as the first frame of a split callback but time out when it appears in an equal-sample coalesced suffix behind a full quantum, violating the required identical terminal and effective-policy outcome.

Task 5.2 requires continuation-delay invariance and terminal/timeout-versus-suffix races, but it gives no expected winner for this case. “Both winner orders” in task 5.1 covers executor ordering, not whether a completed pre-deadline frame reserves an acceptance decision before its continuation executes.

**Required resolution:** choose one normative arrival/processing contract and make every artifact agree. Given the new frame-sample invariant, the coherent choice is to make a fully completed acceptance frame with `receiptSample < deadline` eligible ahead of a later timeout callback, while terminal/shutdown already selected before frame completion still wins. Define how the core records or discovers that pending eligible frame without decoding beyond the service quantum, and how equality remains timeout. Alternatively, retain processing-order timeout priority but explicitly remove policy and terminal outcome from continuation-delay/split-coalesced invariance. Add deterministic barriers for pre-deadline, equal-deadline, and post-deadline frame completion with timeout queued before and after the continuation, asserting effective/requested policy, exact close count, token/continuation residue, and absence of later offers.

## Verified Regression Boundaries

- All provisional, negotiating, active, and disconnecting owners remain inside 16 slots; recent rows remain capped at 64 with deterministic eviction, one manager wake, and zero shutdown ownership.
- Exact-tuple duplicate rejection and separate non-inheriting Bundle-ID variants remain coherent and unauthenticated.
- The undefined `reconnecting` UI state remains removed; returning connections use ordinary negotiating state.
- Observable V1 lower-acceptance attribution, one in-flight offer, requested/effective separation, and conservative acceptance remain intact apart from the timeout/continuation winner conflict above.
- Inbound sequence commits remain atomic per valid whole frame before local expiry/overflow and after hard/token validation. Downlink state still commits only on atomic mailbox ownership.
- Valid excess work pauses without making callback grouping a protocol error; hard total-input, frame/batch, sender-contract, and system-bucket violations still close before the offending frame commits.
- Terminal cleanup continues to clear connection-bound queues, decoder bytes, continuations, and pause ownership without migrating work to a later correlation match.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 2 — 0 High, 2 Medium, and 0 Low.**

The new receipt-time and secure-channel pause mechanisms close the Round 3 architectural gaps, but the continuation state machine still needs a progress transition for trailing partial frames and one unambiguous policy deadline winner rule before implementation can be deterministic and test-complete.
