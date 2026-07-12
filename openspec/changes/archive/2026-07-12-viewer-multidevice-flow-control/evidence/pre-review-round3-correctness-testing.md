# Pre-Implementation Correctness and Testing Review — Round 3

Date: 2026-07-13

## Scope

Re-read `AGENTS.md`, every current artifact in `viewer-multidevice-flow-control`, and all three round-two review reports after the latest remediation. This artifact-only review verified removal of the undefined `reconnecting` presentation state; bounded pause/resume continuation ordering, commit, terminal, split/coalesced, timestamp, and test behavior; and preservation of the prior lifecycle, policy, identity, ingress, and sequence fixes. No production or test source was modified; this report is the only added file.

## Round-Two Correctness Finding Disposition

### Undefined `reconnecting` presentation state — Resolved

The design and normative workspace requirement now list only negotiating, active, disconnecting, and recently disconnected rows, and explicitly state that a returning connection uses ordinary negotiating state with no separate `reconnecting` state (`design.md:129-133`; `spec.md:261-265`). This agrees with the lifecycle transition from a recent row through provisional ownership into negotiating state (`design.md:50-58`; `spec.md:39-69`). No presentation-only generation or unowned reconnect state remains to test.

## Pause/Resume Continuation Verification

The remediation correctly separates hard validity/retention bounds from scheduling quanta. Retained input has a 2 MiB live default and 17 MiB hard maximum, configuration must fit one receive chunk plus one maximum legal frame within Core bounds, and one maximum Event batch must fit atomically inside the record quantum (`design.md:111-113`; `spec.md:183-193`).

The following continuation properties are now deterministic apart from the timestamp issue below:

- **Ordering:** the existing Core decoder retains one ordered suffix; one continuation runs on the same connection-core executor before later receive input; no later byte may overtake; and ownership is limited to one scheduled continuation plus one coalesced successor bit.
- **Commit:** only earlier whole frames may commit. The paused frame and suffix remain uncommitted and byte-charged, and one Event batch cannot split across commits.
- **Terminal behavior:** terminal close invalidates the pending continuation and releases retained input. Task 5.2 requires controlled terminal-versus-suffix races, while task 5.3 requires exact task/handle cleanup and progress by another session between continuation turns.
- **Split/coalesced coverage:** tasks require bounded decoder pause/resume, more than 64 valid small frames, 33 through 128 valid system messages, maximum legal frame and 256-record batch atomicity, split/coalesced comparison, one continuation/successor, and exact queue/token/fairness/sequence state.

## Finding

### NW-MFC-CT-R3-001 — Medium — Split/coalesced equivalence has no coherent timestamp oracle for time-dependent protocol outcomes

**Confidence: 10/10**

The normative requirement says that split and coalesced delivery of the same bytes must produce the same protocol, sequence, queue, token, and terminal outcome. It also says that continuation turns reuse the original callback's monotonic receipt sample, but only for rate accounting (`spec.md:191`). The design is similarly limited to sender/system token accounting (`design.md:115`). Task 5.2 requests split-versus-coalesced equivalence but does not control or assert the timestamp assignment (`tasks.md:27`).

The unqualified equivalence claim is impossible when split callbacks have different receipt times. For example, a second callback can legitimately refill sender/system tokens, while all frames retained from one coalesced callback consume against the first sample. The same ambiguity affects receiver-local TTL conversion/expiry, throughput buckets, and an acceptance frame received before a policy deadline but processed from a continuation after it. The policy rule currently selects acceptance using the time at which it is processed (`spec.md:73-98`), while the continuation rule preserves an earlier sample only for rate accounting. Consequently, scheduling delay can change policy/terminal outcome even though the equivalence requirement says it cannot.

The artifacts also do not define the receipt sample of a frame split across chunks: it could inherit the first-byte callback, the callback that completes the frame, or the continuation's execution time. Each choice produces different token, TTL, and deadline results. A test can therefore make the equivalence suite pass by injecting equal times while another implementation uses execution time for TTL or policy and still appears consistent with part of the prose.

**Required resolution:**

1. Define one frame-availability timestamp rule, normally the monotonic sample of the callback that first makes the complete frame available; retain that sample with every paused whole frame/suffix.
2. Enumerate every time-dependent consumer that uses the retained sample versus continuation execution time, including sender/system buckets, receiver-local TTL/deadline conversion and expiry, policy acceptance deadlines, and throughput telemetry. Preserve the existing exact policy winner rule or explicitly state how a queued continuation participates in it.
3. Scope split/coalesced equivalence to the same bytes under the same injected byte-availability and terminal/timer schedule. State that deliberately later receipt samples may legitimately refill buckets or change expiry/deadline outcomes.
4. Extend task 5.2 with exact timestamped tests for a frame split across chunks, a suffix processed after token refill time, TTL on both sides of continuation delay, policy acceptance received before but serviced after its deadline, and terminal/timeout in both serialized winner orders. Assert exact sequence, queue, token, effective-policy, close-count, retained-byte, continuation, and telemetry state.

## Prior-Fix Regression Check

- All provisional, negotiating, active, and disconnecting owners remain inside the 16-slot cap; recent rows remain separately capped at 64 with deterministic eviction and one manager wake.
- Exact-tuple duplicate claims are rejected, while same-installation different/missing-Bundle variants are separate unauthenticated rows with no nickname, selection, session, or downlink inheritance.
- V1 policy acceptance now distinguishes observable no-pending repetition from an indistinguishable conservative lower pair while one later offer is pending. Non-resetting 10-second monotonic deadlines and terminal winner rules remain intact, subject only to the continuation timestamp ambiguity above.
- Inbound whole-frame sequence commit still occurs before local expiry/overflow and after hard/token validation. Downlink sequence, queue, fairness, token, and telemetry state still commits only with atomic whole-frame mailbox admission.
- Valid coalesced excess work now pauses instead of closing; hard retained/protocol/token violations still close before the offending frame commits.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, and 0 Low.**

The undefined reconnecting state and the structural continuation bounds are resolved. The remaining timestamp contract must be made normative so callback grouping, continuation delay, policy deadlines, TTL, token refill, and terminal races have one implementable and testable outcome.
