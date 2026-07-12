# Pre-Implementation Review Round 6: Security, Performance, and Documentation

## Scope and Verdict

This sixth artifact-only review re-read the current `viewer-multidevice-flow-control` proposal, design, capability specification, task plan, validation record, and Round 5 review reports after the final composed-state remediation. It focused on the ordinary partial-frame resume path versus the recorded-policy-timeout partial/drained no-resume exception, then regressed receive ownership, timeout arbitration, memory/CPU bounds, terminal races, unauthenticated identity, diagnostics, persistence exclusions, documentation, and privacy evidence. No production or test source was modified; this report is the only added file.

The two partial-input paths are now explicitly disjoint and safe:

- In the ordinary path with no recorded policy timeout, `needsMoreBytes` retains and charges the bounded partial frame, discards the old completion sample, atomically detaches the old token/continuation, and resumes exactly one receive. An immediately completing callback supplies the later frame sample and can claim only a fresh generation-valid token.
- During `deadlineElapsed` suffix arbitration, only already-complete pre-deadline frames are eligible. If classification reaches drained or partial-only input without a matching acceptance, timeout closes once, clears even partial decoder bytes, resolves the pause token, and never rearms receive. Post-deadline bytes cannot extend the finite arbitration window.

The normative requirement, scenarios, design, implementation task, deterministic test task, and validation record agree on that priority. No new actionable issue was found.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**

**Approved for this review dimension.** Apply work may begin only after the other independent artifact-review dimensions also report zero findings and task 1.2 is completed under the repository workflow.

## Round 5 Finding Disposition

| Round 5 finding | Round 6 disposition |
| --- | --- |
| `NW-MFC-CT-R5-001`: `deadlineElapsed` plus `needsMoreBytes` had conflicting close and resume transitions | **Resolved.** Recorded timeout is an explicit higher-priority exception to ordinary decoder progress. It classifies only already-complete frames. Reaching drained or partial-only input without acceptance closes, clears bytes/token ownership, and never resumes; ordinary no-timeout partial input retains the charged prefix and resumes once (`design.md:70,116-124`; `spec.md:73-117,210-214`; `tasks.md:8,26-27`). |
| Round 5 architecture/API generic `needsMoreBytes` exception finding | **Resolved.** The generic rule is now expressly limited to the ordinary no-timeout path, while recorded-timeout partial/drained cleanup is normative and separately test-owned (`design.md:120`; `spec.md:212`; `tasks.md:27`; `pre-implementation-validation.md:72-76`). |

## Receive and Timeout Safety Verification

- The secure channel remains the sole receive-loop and Network.framework owner. The internal pause token changes only receive credit, not transport ownership or wire behavior.
- A token can be claimed only during synchronous delivery and is bound to the current channel generation. Claim suppresses eager receive rearm, so no later callback or hidden callback `Data` can coexist with a complete paused frame.
- Exactly one token, ordered decoder suffix, scheduled continuation, and coalesced successor bit may exist per connection. Service turns remain bounded by configured frame, record, and system-message quanta.
- Ordinary `needsMoreBytes` keeps bounded partial decoder bytes charged to the total-input budget. Before permitted resume, session state atomically clears the continuation and detaches the old token. Immediate reentrant completion cannot see or reuse old ownership.
- Recorded timeout never takes the ordinary partial resume path. The timeout deadline is unchanged; only complete frames already owned with a pre-deadline callback sample are classified. Drained or partial-only input without acceptance closes and cannot wait for future bytes.
- A valid matching pre-deadline acceptance commits independent of timeout/continuation queue order. Equality and later receipt samples remain timeout. Protocol/policy violation first closes with its defined terminal result.
- Physical transport terminal, explicit cancellation, decoder failure, attachment rollback, channel cancellation, and shutdown do not defer for suffix arbitration. They invalidate the continuation, release decoder bytes, and resolve an attached token without rearm.
- Resume-first starts at most one generation-matched receive, which a later terminal cancels. Terminal-first starts none. Stale-generation resume is a no-op. Both orders have deterministic zero-residue assertions.
- Tests explicitly distinguish ordinary partial detach/resume with immediate completion and a fresh token from recorded-timeout partial/drained no-resume cleanup. They also cover timeout on both sides of continuation, terminal races, receipt samples, exact retained bytes, close state, and receive count.

## Resource, Trust, and Protocol Verification

- Total connection-owned input includes decoder partial/pending bytes and transient callback `Data`. Overflow-safe configuration requires one maximum encoded frame plus two configured receive chunks. The 2 MiB default and 19 MiB hard cap remain coherent with Core limits and frame overhead.
- Sender-contract and system-message token buckets, hard frame/batch limits, queue service quanta, 128-message burst continuation, mailbox Control reservation, and no blocked immediate retry keep ingress CPU and scheduling finite.
- Each session has two bounded 5,000-Event/16-MiB queues. Sixteen provisional/negotiating/active/disconnecting owners, 64 recent rows, one recent-row wake, bounded preferences, one-shot session scheduling, and latest-only UI publication cap aggregate ownership.
- Whole inbound frames commit contiguous sequence only after structural/route/deadline/token validation and before local expiry/overflow. Downlink sequence, queue, fairness, token, and telemetry commit only with atomic mailbox ownership.
- Exact duplicate rejection uses installation ID plus optional Bundle ID. Other Bundle variants are separate unauthenticated rows and inherit no nickname, selection, session, queue, or downlink authority.
- Downlink work stays bound to one connection ID and epoch and is cleared or terminally dropped rather than migrated through correlation hints.
- Policy offers remain one-at-a-time, conservative, and non-resetting. Frame-completion samples consistently govern policy deadline, token, TTL, and throughput decisions; equal-sample split/coalesced inputs remain equivalent.

## Documentation and Privacy Verification

- All peer installation, Bundle, display, alias, nickname, and recent-row values remain explicitly unauthenticated and cannot authorize replacement or Event retargeting.
- Errors, terminal categories, descriptions, debug descriptions, reflection, interpolation, and logs derive only from closed local codes and exclude Event, peer, route, rate, queue, epoch, endpoint, TLS, raw-byte, and underlying-error content.
- Event drafts, encoded payloads, queue keys, epochs, and queue contents remain absent from persistence, logs, analytics, clipboard, export, UI state, and recent rows. Effective policy is memory-only outside the bounded active snapshot.
- Only bounded requested-policy and nickname preferences use `UserDefaults`, with corruption repair, deterministic eviction, and no transport-callback mutation.
- Task 5.4 requires English operator/architecture documentation plus diagnostic, reflection, presentation, and accessibility tests.
- Task 5.5 requires inspection of the built privacy manifest and an English rationale for existing Device ID and UserDefaults declarations. Privacy sufficiency must be proven by packaged evidence.
- Event history, search/filter, local storage, export, control composition, performance charts, public SDK APIs, wire changes, third-party dependencies, entitlements, internet services, and a second test harness remain excluded.

## Review Gate

This fresh security/performance/documentation review has zero unresolved actionable findings. Preserve these requirements during implementation, match evidence to every scenario, and repeat the independent review dimensions before archive.
