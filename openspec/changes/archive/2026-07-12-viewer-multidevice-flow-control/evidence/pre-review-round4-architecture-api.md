# Pre-Implementation Review Round 4 — Architecture and API

Date: 2026-07-13

## Scope

This artifact-only review re-read `AGENTS.md` and every current artifact under `openspec/changes/viewer-multidevice-flow-control` after Round 3 remediation. It compared the proposed receive-pause contract with the current Core decoder, secure channel, and Viewer connection-core execution model. No production or test source was modified; this report is the only added file.

The review specifically verified same-sample timestamp qualification and the complete cross-layer receive-pause contract: synchronous claim, receive rearm suppression, one token/suffix/continuation, 2 MiB default and 19 MiB hard accounting, stale generations, terminal cleanup, compatibility for nonclaiming consumers, and internal Core scope.

## Finding

### 1. Medium — Receipt-time deadline semantics conflict with queue-order timeout victory for a retained suffix

The revised ingress contract gives every completed frame the monotonic sample of the callback that completes its bytes. A frame already complete in a retained suffix keeps that sample through continuation delay, and the sample governs policy-deadline comparison; scheduling delay must not change it (`design.md:119`; `specs/viewer-multidevice-flow-control/spec.md:195,234-238`).

The policy state machine still says acceptance is valid only when it is processed before the deadline and that a timeout processed first on the core serial queue selects the terminal gate (`design.md:70`; `spec.md:73-75,94-98`). Those rules conflict when an acceptance frame is complete inside a paused suffix. For example, a callback sampled before the policy deadline may consume its 64-frame turn and retain the acceptance as frame 65. If the deadline task is already queued, or becomes queued before the continuation block, it can run first and close the session even though the acceptance's immutable frame sample is before the deadline. The same bytes and frame samples can then have a different terminal result solely because continuation scheduling placed timeout ahead of already-received input.

The artifacts request continuation-delay invariance and terminal/timeout-versus-suffix tests (`tasks.md:27`) but do not define which owner wins this case. The terminal-race scenario covers only the case where terminal close wins (`spec.md:240-244`), not how a deadline arbitrates against a complete earlier-sampled policy frame. Therefore the implementation cannot simultaneously satisfy receipt-sample authority, queue-first terminal victory, and equal-sample split/coalesced terminal equivalence.

**Required resolution:** define one total arbitration rule for pending received work versus scheduled deadlines. The recommended rule is that claiming the receive-pause token also records the bounded suffix's frame-completion sample ownership; before a policy timeout commits, it must defer behind already-complete retained frames whose immutable sample is earlier than the deadline. The continuation then validates and commits or rejects those frames in bounded turns, after which a still-current timeout may run. A frame completed with a sample equal to or later than the deadline remains timeout, and transport terminal/shutdown may still invalidate the suffix immediately if that is the intended higher-priority safety rule. Alternatively, retain pure core-queue victory but remove the claims that receipt sample governs policy deadlines and that continuation delay cannot change terminal outcome. Update the state table, terminal/timeout-versus-suffix scenarios, and task oracle for both winner orders.

## Round 3 Remediation Verification

- **Same-sample qualification:** resolved for TTL, token buckets, throughput, and ordinary receive decisions. Equal frame samples are required for callback-partition equivalence, while genuinely later split samples may cause only defined time-based differences (`design.md:119`; `spec.md:195`; `tasks.md:27`). The finding above is limited to the unresolved interaction with an independently queued policy timeout.
- **Synchronous receive-pause claim:** resolved. One internal generation-bound token can be claimed only during synchronous `.received` delivery. A successful claim suppresses the channel's eager driver rearm before the handler returns; claim failure is terminal (`design.md:115`; `spec.md:191`).
- **Single ownership:** resolved. The connection core owns exactly one token, one bounded decoder suffix, and one same-executor continuation. No later callback, callback-ingress `Data`, or byte exists while paused, and nonclaiming consumers retain the existing eager receive loop (`design.md:115-117`; `spec.md:191-193`).
- **Input accounting:** resolved. Total input covers decoder partial/pending storage and transient callback `Data`; overflow-safe configuration requires one maximum legal encoded active frame plus twice the configured receive chunk. The 2 MiB default and corrected 19 MiB hard cap cover repository defaults and the 16 MiB-plus-overhead frame with two hard-maximum 1 MiB chunks (`design.md:111`; `spec.md:187`).
- **Generation and terminal cleanup:** resolved. Resume is once-only and generation-bound; stale resume is a no-op. Terminal, decoder failure, attachment rollback, channel cancellation, or shutdown invalidates the continuation, releases decoder bytes, resolves the token without rearm, and has explicit controllable-driver coverage (`design.md:117`; `spec.md:193,228-244`; `tasks.md:8,27`).
- **Architecture boundary:** resolved. Decoder pause/retained-byte observation and secure-channel receive control are narrow, platform-neutral internal Core seams. Viewer retains protocol policy, session scheduling, persistence, lifecycle, and UI. No supported SDK API, wire schema, callback owner, decoder owner, transport, entitlement, nested manifest, or third-party dependency is introduced (`proposal.md`; `design.md:26,34`; `tasks.md:8`).
- **Prior remediations:** observable conservative V1 acceptance, exact-tuple duplicate rejection, distinct Bundle variants, removal of reconnecting state, synchronous same-core attachment, 16 session owners, and 64 recent rows remain coherent.

## Verdict

**Approval withheld.** The cross-layer receive-pause token and resource contract now close the Round 3 ownership findings, but policy timeout arbitration must be reconciled with the newly authoritative frame receipt sample.

**Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, 0 Low.**
