# Pre-Implementation Review Round 4: Security, Performance, and Documentation

## Scope and Verdict

This fourth artifact-only review re-read the current `viewer-multidevice-flow-control` proposal, design, capability specification, task plan, validation record, and Round 3 reports after remediation. It verified the new internal receive-pause ownership against the existing eager secure-channel receive loop and audited total input accounting, receipt-time propagation, terminal cleanup, exact-tuple correlation, privacy evidence, and finite resource/test ownership. No production or test source was modified; this report is the only added file.

The generation-bound receive-pause token resolves the Round 3 transport-ownership defect. It is claimed synchronously during delivery, prevents eager driver rearm, permits no second callback `Data`, stays with one decoder suffix and one continuation, resumes once after drain, and resolves without rearm on terminal paths. The 2 MiB default and corrected 19 MiB hard total-input budget coherently cover one maximum encoded frame plus two receive chunks, including the 5-byte frame overhead at Core hard maxima. Receipt samples now follow frame completion and govern all receive-time decisions, with split/coalesced equivalence correctly qualified by equal sample schedules.

One new protocol-winner contradiction remains. A policy acceptance may be fully available before its deadline but retained behind a service-turn pause. The artifacts require its preserved receipt sample to govern the policy deadline and require continuation delay not to change the result, while also allowing a separately queued timeout callback to win first and invalidate that suffix. No rule gives the pre-deadline retained frame priority or tells timeout to defer until the bounded suffix is classified.

**Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, and 0 Low.**

**Approval withheld.** Resolve the timeout-versus-retained-input winner rule, strictly revalidate the artifacts, and obtain a fresh zero-finding review before production or test implementation begins.

## Round 3 Finding Disposition

| Round 3 finding | Round 4 disposition |
| --- | --- |
| `NW-MFC-SPD3-001`: decoder-only pause could not stop secure-channel rearm | **Resolved.** Proposal impact, design, normative requirements, implementation tasks, and controllable-driver tests now own a narrow internal generation-bound receive-pause token. A successful synchronous claim suppresses rearm; only one token/suffix/continuation exists; terminal and stale generations cannot revive receive; consumers that never claim preserve existing eager behavior (`proposal.md:8,29`; `design.md:111-119`; `spec.md:187-195,222-244`; `tasks.md:8,27`). |
| Round 3 architecture/API total-retention finding | **Resolved.** Total connection-owned input includes decoder partial/pending bytes and transient callback `Data`. Overflow-safe configuration requires one maximum legal encoded active frame plus twice the configured receive chunk. The 2 MiB live default is coherent with default Core limits, and the corrected 19 MiB hard cap covers the 16 MiB payload, 5-byte frame overhead, and two 1 MiB hard-maximum chunks (`design.md:111`; `spec.md:187`). |
| Round 3 timestamp/equivalence findings | **Partially resolved; one winner contradiction remains.** A completed frame receives the sample of its completing callback, retains it across continuation, and uses it for tokens, TTL, policy deadline, throughput, and every other receive-time decision. Equal-sample callback partitions must be equivalent; deliberately later samples may cause only defined later time-based outcomes (`design.md:119`; `spec.md:195,234-238`; `tasks.md:27`). Finding `NW-MFC-SPD4-001` concerns a timeout task overtaking an already received but paused frame. |

## Finding

### NW-MFC-SPD4-001 — Medium — Timeout can overtake a pre-deadline acceptance retained behind a service quantum

**Evidence**

- Policy acceptance is valid only before its non-resetting deadline. The existing winner model says the core serial queue selects one winner, and timeout or terminal processed first closes and prevents later effective-state mutation (`design.md:64-81`; `spec.md:73-98`).
- The new receive-time rule says the frame-completion receipt sample governs policy-deadline comparison and that continuation scheduling delay cannot change it (`design.md:119`; `spec.md:195`). Task 5.2 explicitly requires continuation-delay invariance for policy-deadline decisions (`tasks.md:27`).
- Service work may stop after 64 frames and retain the next whole frame/suffix for an asynchronous same-core continuation (`design.md:113-121`; `spec.md:189-197`). The receive-pause token prevents later network input, but it does not by itself order an already scheduled deadline callback behind every continuation turn.
- Consider one callback sampled at `deadline - 1` that contains 64 valid frames followed by a valid conservative policy acceptance. The first turn consumes its frame quantum and pauses before the acceptance. If the deadline callback is already queued ahead of the continuation, the timeout-first rule closes, invalidates the continuation, and discards the acceptance even though that frame was fully available with a pre-deadline receipt sample. If the acceptance appears within the first 64 frames, or the service quantum is configured higher, it commits before the same timeout.
- The normative terminal-race scenario only states the result when terminal close wins (`spec.md:240-244`). It does not define whether a policy timeout is permitted to win over retained input whose completion sample predates the deadline. The test task names timeout-versus-suffix races but supplies no required winner for this exact ordering (`tasks.md:27`).

**Impact**

Policy validity can again depend on a local scheduling quantum rather than the preserved receive-time contract. Under load, a conforming App may be disconnected even though its complete acceptance arrived before the advertised deadline. The behavior also breaks equal-sample split/coalesced equivalence and permits two implementations to make opposite effective-policy and terminal decisions from the same bytes, timestamps, and task order.

The retained suffix is strictly bounded, so resolving the ambiguity does not require unbounded grace or repeated timeout extension. It requires one explicit winner rule for input the connection already owns.

**Required remediation**

1. Define the winner for a timeout racing a paused suffix. The recommended rule is: when the channel owns a bounded suffix containing frames completed with a sample before the pending policy deadline, the timeout callback records that the deadline elapsed but cannot terminally commit until those already received frames are classified in order. A valid attributed acceptance commits by its receipt sample; invalid or absent acceptance then allows timeout to close. No new network receive or deadline reset occurs during this bounded classification.
2. Alternatively, if timeout-first queue order must remain authoritative, remove the claim that the frame receipt sample governs policy deadlines and that continuation delay is invariant. Explicitly document that an acceptance must be decoded before the timeout task wins. This weaker behavior must still be independent of configurable service quantum to satisfy split/coalesced equivalence, which likely requires scheduling every continuation ahead of the deadline callback.
3. Reconcile `processed with now < deadline`, frame-receipt comparison, and terminal-first language in the design, state table, and normative scenarios. Identify whether `now` means the preserved frame-completion sample or continuation execution time.
4. Add deterministic tests for an acceptance as the first paused frame at `deadline - 1`, equality, and `deadline + 1`; force the timeout task before and after continuation; vary the frame quantum around the acceptance position; cover both initial and dynamic offers; and assert exact effective/requested policy, close count/category, token, sequence, retained bytes, pause token, continuation, and receive-rearm state.
5. Prove that the bounded pre-deadline classification cannot be abused to extend the deadline: no later callback can exist while receive is paused, only the already charged suffix is eligible, the original deadline never moves, and terminal/shutdown still cancels immediately under their separately defined winner rules.

## Verified Security, Performance, Privacy, and Documentation Boundaries

- The internal receive-pause token is generation-bound, idempotent, and available only during synchronous delivery. A claimed token prevents driver rearm and hidden callback `Data`; resume after drain starts one receive, while terminal resolution and stale resume cannot rearm.
- Total input accounting is overflow-safe and includes decoder partial/pending storage plus transient callback ownership. The 19 MiB hard limit is arithmetically sufficient for Core's hard encoded-frame and two hard receive-chunk bounds.
- A frame fragmented across callbacks uses the later completing sample. A frame completed in retained input keeps its sample across continuation, so token refill, TTL origin, throughput buckets, and other receive-time state do not drift with executor delay.
- Service turns, system bursts, callback frames/records, queue publication, expiry, and telemetry all remain finite. A valid 128-system-message burst may span four default turns without becoming a callback-grouping violation.
- Terminal, decoder failure, attachment rollback, channel cancellation, and shutdown own explicit continuation, token, decoder-byte, handle, queue, recent-row, and task cleanup. Tests require stale resume, immediate driver completion, and zero-residue terminal behavior.
- Exact tuple correlation rejects only matching installation-ID/optional-Bundle-ID live claims. Different or missing Bundle variants remain separate unauthenticated rows and inherit no nickname, selection, session, or downlink authority.
- Connection-bound downlink work is cleared or terminally dropped and never migrates to a later correlation match.
- Session, recent-row, preference, queue, mailbox, timer, continuation, UI-snapshot, and diagnostic ownership remains explicitly bounded.
- Diagnostics derive only from closed local codes and exclude Event, peer, route, policy, queue, endpoint, TLS, wire-byte, and underlying-error data. Telemetry failure cannot block or terminate a session.
- Event payloads, drafts, encoded data, queue keys, epochs, and queue contents remain absent from persistence, UI state, recent rows, logs, analytics, clipboard, and export. Effective policy remains memory-only outside the bounded live snapshot.
- Task 5.5 requires inspection of the built privacy manifest and an English rationale for existing Device ID and UserDefaults declarations. Privacy coverage remains an evidence gate rather than a source-code assumption.
- Event history, search/filter, local storage, export, control composition, performance charts, new public SDK APIs, wire changes, third-party dependencies, entitlements, and another test harness remain excluded.

## Required Artifact Gate

Revise the design, capability specification, tasks, and pre-implementation validation record to resolve `NW-MFC-SPD4-001`. Then obtain a fresh review round across architecture/API, correctness/testing, and security/performance/documentation. Production and test implementation must not begin until every dimension reports zero unresolved actionable findings.
