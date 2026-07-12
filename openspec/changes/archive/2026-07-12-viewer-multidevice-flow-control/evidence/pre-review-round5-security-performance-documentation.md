# Pre-Implementation Review Round 5: Security, Performance, and Documentation

## Scope and Verdict

This fifth artifact-only review re-read the current `viewer-multidevice-flow-control` proposal, design, capability specification, task plan, validation record, and Round 4 review reports after remediation. It verified bounded policy-timeout deferral, complete-frame versus partial-tail decoder progress, pause-token detach/resume ordering, immediate receive completion, terminal/stale-generation cleanup, aggregate resource limits, exact-tuple correlation, diagnostics, persistence exclusions, and privacy evidence. No production or test source was modified; this report is the only added file.

The Round 4 timeout and partial-tail findings are resolved. A timeout may defer terminal commit only for the already-owned, charged, receive-paused suffix completed before the unchanged policy deadline. No receive is rearmed and no new bytes can enter during this finite classification. A matching timely acceptance may commit; absence or an earlier violation commits the recorded timeout exactly once, while equality or a later sample receives no deferral. Physical terminal, cancellation, and shutdown remain immediate winners.

Decoder progress now distinguishes a paused complete frame, a charged partial tail that needs more bytes, and drained input. Only a complete paused frame retains the token and continuation. Partial-tail and drained paths atomically clear continuation ownership and detach the old token before invoking its one resume, so an immediately completing receive cannot observe or reuse that token and may claim only a fresh generation-valid token. Both resume-first and terminal-first orders are finite and converge to zero residue after terminal cleanup.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**

**Approved for this review dimension.** Source implementation may begin only after the architecture/API and correctness/testing dimensions also report zero unresolved findings and task 1.2 is completed under the repository workflow.

## Round 4 Finding Disposition

| Round 4 finding | Round 5 disposition |
| --- | --- |
| `NW-MFC-SPD4-001`: timeout could overtake a pre-deadline acceptance retained behind a service quantum | **Resolved.** Frame-completion time is now the sole policy-deadline sample. Timeout records `deadlineElapsed` instead of invalidating an already-owned pre-deadline suffix, keeps receive paused, and lets only that finite suffix be classified without resetting or extending the deadline. A matching pre-deadline acceptance commits independent of timeout/continuation queue order; absence or violation closes once; equality and later samples do not defer (`design.md:64-82`; `spec.md:73-111`; `tasks.md:26-27`). |
| `NW-MFC-CT-R4-001`: paused suffix ending in a partial frame had no progress transition | **Resolved.** Decoder results explicitly distinguish `pausedOnCompleteFrame`, `needsMoreBytes`, and `drained`. A partial tail remains charged but loses its old completion sample, then detaches the old token and continuation before one receive resumes. The callback that completes the frame provides the later receipt sample and may claim one fresh token (`design.md:116-124`; `spec.md:200-210,249-271`; `tasks.md:8,27`). |
| `NW-MFC-CT-R4-002`: receipt-time policy arbitration conflicted with timeout-first ordering | **Resolved.** The state table and normative scenarios now state one bounded suffix-arbitration winner, including deadline-minus-one, equality, deadline-plus-one, timeout-before/after-continuation, and immediate physical terminal/shutdown behavior (`design.md:70-82`; `spec.md:73-111`; `tasks.md:26-27`). |

## Security and Performance Verification

### Receive pause, retained input, and progress

- A generation-bound internal pause token may be claimed only during the synchronous `.received` delivery. A successful claim prevents the secure channel from rearming the driver, so no second callback, callback-ingress `Data`, or later byte exists while a complete frame is paused.
- Exactly one token, one decoder suffix, one scheduled continuation, and one coalesced successor bit may exist for a session. Every service turn remains finite.
- The total connection-owned input budget includes decoder partial/pending bytes and the transient callback `Data`. Overflow-safe configuration requires one maximum legal encoded active frame plus twice the configured receive chunk. The 2 MiB live default and 19 MiB hard maximum are coherent with Core's default and hard limits, including encoded-frame overhead.
- `pausedOnCompleteFrame` alone retains the pause token. `needsMoreBytes` preserves and charges only the bounded partial tail. `drained` retains no decoder input.
- Partial-tail and drained transitions atomically remove session references to the old token and continuation before resume. Immediate synchronous receive completion therefore cannot reuse old ownership, and at most one fresh token can be claimed by the new callback.
- Failure to claim while pausing is terminal rather than accepting unowned input. Terminal, decoder failure, attachment rollback, channel cancellation, and shutdown invalidate continuation ownership, release decoder bytes, and resolve any attached token once without rearming.
- Resume-first starts at most one generation-matched receive that a later terminal cancels. Terminal-first makes resume a no-op. Stale-generation resume cannot revive a channel. Tests require exact zero token, continuation, callback-Data, decoder, receive-request, handle, and queue residue.

### Receipt time and timeout deferral

- Every callback carries one injected monotonic sample. A frame uses the callback that completes it; retained complete frames preserve that sample, while a fragmented frame uses the later completing callback.
- The frame sample consistently governs sender/system buckets, receiver-local TTL, policy deadlines, throughput, and all other receive-time decisions. Executor delay cannot refill tokens or age already completed input differently.
- Split/coalesced equivalence is correctly scoped to equal completed-frame sample schedules. Deliberately later split samples may produce only the documented later time-based effects.
- Policy timeout deferral is finite: it covers only one already-owned bounded suffix whose completion sample precedes the unchanged deadline. Receive remains paused; the deadline is neither reset nor extended; no later callback can become eligible.
- If the finite suffix contains a matching acceptance, it may commit. If it drains without one, reaches only a partial tail, or encounters a protocol/policy violation first, the recorded timeout or violation closes without rearming. A sample equal to or later than the deadline cannot mutate effective policy.
- Physical transport terminal, explicit cancellation, and shutdown do not wait for suffix arbitration because the session cannot remain live. Both serialized winner orders are test-owned.

### Other bounded trust and resource surfaces

- The 16-slot registry includes provisional, negotiating, active, and disconnecting owners through exact handle cleanup. Recent rows remain separately capped at 64 with deterministic expiry/eviction and one manager wake.
- Exact live duplicates are defined by the installation-ID plus optional-Bundle-ID tuple. Different or missing Bundle-ID variants are separate unauthenticated rows and inherit no nickname, selection, session, queue, or downlink authority.
- Downlink work belongs to an exact connection ID and epoch, is cleared or terminally dropped, and never migrates through an unauthenticated correlation match.
- Two 5,000-Event/16-MiB queues per session, finite service turns, token buckets, mailbox Control reservation, coalesced system messages, saturating telemetry, one-shot scheduling, and latest-only UI publication bound memory and work.
- A valid 128-message system burst may span four default turns. Callback grouping alone cannot close a conforming peer; hard retained-input, frame/batch, sender-contract, and system-bucket violations still close before the offending frame commits.
- Policy offers remain one-at-a-time with non-resetting deadlines, conservative V1 acceptance, requested/effective separation, and observable handling of indistinguishable lower responses.

## Privacy and Documentation Verification

- New terminal/error/description/debug/reflection/interpolation/log surfaces derive only from closed local codes. They exclude Event content and type, metadata, peer identifiers, nicknames, routes, queue keys/values, rates, epochs, endpoint/TLS data, raw bytes, and arbitrary underlying errors.
- Event drafts, encoded payloads, queue keys, session epochs, and queue contents remain absent from `UserDefaults`, logs, analytics, clipboard, export, UI state, and recent rows. Effective policy remains absent from persistence and unintended surfaces, appearing only in the bounded live snapshot.
- Only bounded requested-policy and nickname preferences persist. Correlation and recent rows remain explicitly unauthenticated and cannot authorize replacement or retarget delivery.
- Task 5.4 requires English architecture/operator documentation and closed diagnostic, reflection, presentation, and accessibility tests.
- Task 5.5 requires inspection of the built privacy manifest plus an English rationale establishing whether existing Device ID and UserDefaults declarations cover the implemented behavior. Privacy sufficiency is therefore demonstrated by packaging evidence, not assumed from source.
- Event history, search/filter, local storage, JSON export, control composition, performance charts, public SDK API, wire-schema changes, third-party dependencies, entitlements, cloud service, and another test harness remain outside this change.

## Review Gate

This security/performance/documentation dimension has no unresolved actionable finding. Preserve these boundaries during apply work, save exact implementation evidence, and run the required independent completion reviews before archiving the change.
