# Pre-Implementation Review Round 5 — Architecture and API

Date: 2026-07-13

## Scope

This artifact-only review re-read `AGENTS.md` and every current artifact under `openspec/changes/viewer-multidevice-flow-control` after Round 4 remediation. It rechecked the proposed internal Core decoder/channel seams against the existing Viewer same-core ownership model and recalculated all stated input bounds. No production or test source was modified; this report is the only added file.

The review specifically verified that policy timeout deferral is limited to an already-owned pre-deadline suffix, and that decoder `pausedOnCompleteFrame`, `needsMoreBytes`, and `drained` progress composes with detach-before-resume token ownership, immediate receive completion, stale generations, and terminal cleanup.

## Finding

### 1. Low — The generic `needsMoreBytes` requirement does not state the elapsed-policy-timeout exception

The policy requirement now correctly says that a timeout defers only while already-complete pre-deadline frames remain in the owned suffix. If classification reaches `needsMoreBytes` with only a partial tail and no acceptance, the recorded timeout closes, clears partial bytes, resolves the token, and must not rearm receive (`design.md:70`; `specs/viewer-multidevice-flow-control/spec.md:77,113-117`).

The later normative decoder requirement still says without qualification that `needs-more-bytes SHALL ... resume one receive`, and the ordinary partial-tail scenario repeats that behavior (`spec.md:212,255-259`). For the combined `deadlineElapsed + needsMoreBytes` state, one normative clause therefore says “SHALL NOT resume” while another says “SHALL resume.” The intended special case is clear from the policy section, but the specification provides no explicit precedence or exception in the generic state transition. Task 5.1/5.2 also names timeout-versus-suffix and partial-tail behavior separately without explicitly requiring their combined no-rearm cleanup oracle (`tasks.md:26-27`).

**Required resolution:** qualify the generic decoder rule and ordinary partial-tail scenario with “when no recorded policy timeout applies.” State there that `deadlineElapsed + needsMoreBytes/drained` follows the policy exception: close once, discard partial bytes, resolve the token without rearm, and retain no continuation. Add the combined deterministic test explicitly to task 5.1 or 5.2. This is a contract-editing correction; it does not require a new API or architecture.

## Round 4 Remediation Verification

- **Policy timeout arbitration:** resolved in architecture. Timeout defers only for one already-owned paused suffix sampled before its deadline, records elapsed without extending/resetting the deadline, and classifies only complete earlier-received frames. Equality/later samples do not defer; physical terminal, explicit cancellation, and shutdown invalidate the suffix immediately (`design.md:70-82`; `spec.md:73-117`).
- **Decoder progress model:** coherent once the finding's exception is made explicit. `pausedOnCompleteFrame` alone retains one token and schedules another bounded turn. Ordinary `needsMoreBytes` preserves charged partial bytes, discards the old completion sample, and resumes for later completion; `drained` owns no decoder residue (`design.md:116-122`; `spec.md:210-216`).
- **Detach before resume:** resolved. The core atomically clears continuation state and detaches the token before resume, so an immediately completing driver callback sees no stale token and can claim at most one fresh generation-matched token. Resume-first and terminal-first behavior is explicitly test-owned (`design.md:120-122`; `spec.md:212-214,273-277`; `tasks.md:8,27`).
- **Receive-pause ownership:** resolved. Claim is synchronous during `.received`, prevents rearm, and leaves exactly one token/suffix/continuation. Failure to claim is terminal; nonclaiming Core consumers retain eager receive behavior; stale-generation resume is a no-op.
- **Input arithmetic:** correct. The hard maximum encoded frame is 16 MiB plus 5 bytes, and two hard-maximum receive chunks are 2 MiB. Their sum is 18,874,373 bytes, below the 19 MiB cap of 19,922,944 bytes. Repository defaults likewise fit below 2 MiB. Overflow-safe cross-field validation remains mandatory (`design.md:112`; `spec.md:206`).
- **Timestamp qualification:** resolved. Equal callback partitions compare the same completed-frame samples; a fragmented frame uses the later callback that completes it; genuinely later samples may cause only defined later time-based outcomes. Continuation delay does not rewrite a completed frame's sample.
- **Core/Viewer boundary:** resolved. Paused/needs-more/drained decoder progress, retained-byte observation, and the generation-bound receive token are narrow platform-neutral internal Core capabilities. Viewer remains the owner of policy arbitration, session state, scheduling, persistence, UI, and lifecycle. No supported SDK API, wire schema, Network.framework owner, decoder owner, nested manifest, entitlement, or third-party dependency is added.
- **All earlier resolutions:** conservative V1 attribution, exact tuple/Bundle-variant behavior, removal of reconnecting state, synchronous reentrant attachment, 16 session-owner slots, 64 recent rows with one wake, connection-bound downlink work, bounded queues, and content-free telemetry remain consistent.

## Verdict

**Approval withheld.** The architecture and ownership model now close the prior findings, but one conflicting generic `needsMoreBytes` clause must explicitly acknowledge the elapsed-policy-timeout exception.

**Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, 1 Low.**
