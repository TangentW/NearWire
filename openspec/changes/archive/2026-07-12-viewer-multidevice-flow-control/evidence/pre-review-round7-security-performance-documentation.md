# Pre-Implementation Review Round 7: Security, Performance, and Documentation

## Scope and Verdict

This seventh artifact-only review re-read every current `viewer-multidevice-flow-control` artifact and the Round 6 architecture/API, correctness/testing, and security/performance/documentation reports. It specifically verified that the 16-slot product bound and evidence cover a mixed registry of provisional, negotiating, active, and disconnecting owners through exact cleanup, then regressed all receive-pause, timeout, memory, CPU, identity, diagnostic, persistence, documentation, and privacy boundaries. No production or test source was modified; this report is the only added file.

The four-state capacity omission is resolved. Proposal, design goal, implementation decision, normative requirement, unit task, and integration task all describe the same finite owner set. Deterministic unit evidence must exercise pure and mixed four-state ownership through cleanup. Integration evidence must hold a barrier-controlled mixed 16-owner registry, reject the 17th handoff, preserve the existing owners, and prove exact cleanup before capacity returns.

No security, performance, documentation, privacy, or resource regression was found.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**

**Approved for this review dimension.** Apply work may begin only after the other current artifact-review dimensions also report zero findings and task 1.2 is completed under the repository workflow.

## Round 6 Finding Disposition

### Four-state 16-slot mixed-registry evidence — Resolved

- The change overview now bounds every mixture of provisional, negotiating, active, and disconnecting App owners to 16 through exact cleanup (`proposal.md:7`).
- The design goal and manager decision use the same four states, claim capacity synchronously, retain it through handle cleanup, and reject a 17th handoff without creating another task (`design.md:13,30-38`).
- The normative requirement explicitly includes all four states and requires a 17th rejection for any 16-owner mixture (`spec.md:3-13`). A live slot remains held through disconnecting and releases only after exact cleanup (`spec.md:43-45`).
- Task 5.1 requires exact pure and mixed provisional/negotiating/active/disconnecting ownership through cleanup. Task 5.3 separately requires a barrier-controlled mixed 16-owner integration registry with 17th rejection and exact multi-session handle/slot/task cleanup (`tasks.md:26,28`).
- The validation record identifies and records the four-state evidence correction before source implementation (`pre-implementation-validation.md:72-74`).

This coverage prevents an implementation from releasing its provisional slot during attachment, omitting negotiation from capacity, or releasing disconnecting ownership before transport cleanup while still passing only fully active tests.

## Security and Resource Verification

### Session and identity ownership

- The 16 product slots are distinct from the admission layer's 32 connection-owner safety bound. Provisional rollback remains owned by admission cleanup; successful transfer retains the exact handle through disconnecting cleanup.
- Recent disconnected rows remain a separate 64-row, 30-second, memory-only bound with deterministic eviction, one manager wake, generation checks, and zero shutdown ownership. The complete UI snapshot remains bounded to 16 owned plus 64 recent rows.
- Exact live duplicate rejection uses installation ID plus optional Bundle ID. Different or missing Bundle variants remain separate unauthenticated rows and inherit no nickname, selection, session, queue, or downlink ownership.
- Peer-declared identity, display, version, alias, nickname, Bundle ID, and recent continuity remain presentation hints only. They cannot authenticate a peer, replace a healthy connection, or retarget Event delivery.
- Downlink values remain owned by one internal connection ID and session epoch. Terminal cleanup clears or drops them and never migrates them through correlation hints.

### Receive, timeout, and terminal ownership

- The internal generation-bound receive-pause token may be claimed only during synchronous delivery. A successful claim prevents eager driver rearm, so no second callback, hidden callback `Data`, or later byte can coexist with a complete paused frame.
- Exactly one token, ordered decoder suffix, scheduled continuation, and coalesced successor bit may exist. Each turn remains finite.
- Decoder progress distinguishes paused complete input, bounded partial input that needs more bytes, and drained state. Ordinary partial/drained paths detach the old continuation and token before one receive resume; immediate completion can claim only a fresh token.
- Recorded policy timeout is an explicit higher-priority exception. It classifies only already-complete pre-deadline frames. Drained or partial-only input without acceptance closes, clears bytes/token state, and never resumes for post-deadline input.
- Frame-completion receipt samples consistently govern sender/system buckets, receiver-local TTL, policy deadline, throughput, and all other receive-time decisions. Equal-sample split/coalesced input remains equivalent.
- Physical terminal, explicit cancellation, decoder failure, attachment rollback, channel cancellation, and shutdown invalidate suffix/continuation ownership immediately. Resume-first and terminal-first orders are bounded; stale-generation resume cannot rearm; terminal evidence requires zero residue.

### Memory, CPU, and scheduling bounds

- Total connection-owned input includes decoder partial/pending bytes and transient callback `Data`. Overflow-safe configuration requires one maximum legal encoded frame plus two receive chunks. The 2 MiB live default and 19 MiB hard cap remain coherent with Core frame overhead and hard receive limits.
- Each session's uplink and downlink queues remain capped at 5,000 Events and 16 MiB. Negotiated single-Event limits, atomic batch ownership, priority overflow, expiry, and keep-latest behavior preserve the bound.
- Sender-contract and system-message token buckets, frame/record/system service quanta, a four-turn valid 128-message burst, mailbox Control reservation, and blocked-work no-immediate-retry rules bound ingress CPU and scheduling.
- Inbound sequence commits only for a structurally and route-valid whole frame after hard/token/deadline checks. Downlink sequence, queue, fairness, tokens, and telemetry commit only after atomic whole-frame mailbox admission.
- One-shot deadlines, one manager recent-row wake, one continuation, no repeating idle timer, bounded snapshot publication, and latest-only main-model delivery prevent task and UI backlog growth.
- One blocked, slow, malformed, over-rate, full, or disconnecting device cannot serialize another session's protocol, queue, telemetry, or cleanup work.

## Documentation and Privacy Verification

- Errors, terminal categories, descriptions, debug descriptions, reflection, interpolation, and logs derive only from closed local codes. They exclude Event content/type, metadata, peer identifiers, nicknames, routes, rates, queue values/keys, epochs, endpoint/TLS material, raw bytes, and arbitrary underlying errors.
- Event drafts, encoded payloads, queue keys, session epochs, and queue contents remain absent from `UserDefaults`, logs, analytics, clipboard, export, UI state, and recent rows. Effective policy remains memory-only outside the bounded active snapshot.
- Persistent state is limited to bounded requested-policy and nickname records with versioning, deterministic eviction, corruption recovery, and no transport-callback mutation.
- Task 5.4 requires English architecture/operator documentation and closed diagnostic, reflection, presentation, and accessibility coverage.
- Task 5.5 requires built privacy-manifest inspection and an English rationale determining whether existing Device ID and UserDefaults declarations cover the implemented behavior. Privacy sufficiency remains a packaging-evidence gate.
- Event history, timeline/search/filter, local storage, JSON export, control composition, performance charts, public SDK APIs, wire changes, third-party dependencies, entitlements, cloud services, and a second test harness remain excluded.

## Review Gate

This fresh security/performance/documentation review has zero unresolved actionable findings. Preserve the four-state capacity evidence and all bounded trust, receive, scheduling, diagnostic, persistence, and privacy requirements during implementation and completion review.
