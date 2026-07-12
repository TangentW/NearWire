# Pre-Implementation Review Round 6 — Architecture and API

Date: 2026-07-13

## Scope

This artifact-only review re-read `AGENTS.md` and every current artifact under `openspec/changes/viewer-multidevice-flow-control` after Round 5 remediation. It rechecked all prior architecture/API findings, the complete Viewer/Core ownership model, the internal decoder and secure-channel receive-control seams, and the final policy-timeout/decoder-progress composition. No production or test source was modified; this report is the only added file.

## Verification

### Generic decoder progress and the recorded-timeout exception

The previous normative conflict is resolved. The generic decoder requirement now explicitly limits `needsMoreBytes` and `drained` receive resume to the ordinary path with no recorded policy timeout. The recorded-policy-timeout rule is a named exception: once no complete pre-deadline frame remains, partial-only or drained input without a matching acceptance closes exactly once, clears partial bytes, resolves the token, and does not resume receive (`design.md:70,120`; `specs/viewer-multidevice-flow-control/spec.md:77,113-117,212`).

The ordinary partial-tail scenario also requires that no policy timeout is recorded before detach and resume, while task 5.2 now separately owns ordinary partial-tail resume and recorded-timeout partial/drained no-resume cleanup (`spec.md:255-259`; `tasks.md:27`). Implementations and tests therefore have one unambiguous oracle for both branches.

### Receive-pause and decoder ownership

- The platform-neutral Core decoder has finite `pausedOnCompleteFrame`, `needsMoreBytes`, and `drained` progress plus retained-byte observation. Only a complete paused frame retains the token and another continuation.
- One generation-bound internal secure-channel token is claimed synchronously during the current `.received` handler. A successful claim prevents eager driver rearm; claim failure closes rather than accepting input without ownership.
- Viewer retains exactly one token, one ordered decoder suffix, and one same-executor continuation. No second callback, callback-ingress `Data`, or later byte exists while paused.
- Before an ordinary permitted resume, Viewer atomically clears continuation state and detaches the old token. An immediately completing next receive therefore sees no stale state and can claim at most one fresh token.
- Resume-first starts at most one generation-matched receive that terminal cleanup can cancel. Terminal-first, decoder failure, attachment rollback, channel cancellation, or shutdown clears decoder state and resolves the token without rearm. Stale-generation resume is a no-op.
- Core consumers that never claim a token preserve the existing eager receive behavior, so the seam does not silently change SDK or other transport consumers.

### Input and timing contracts

- Input accounting is arithmetically coherent. A 16 MiB payload plus the 5-byte encoded-frame overhead and two 1 MiB hard-maximum receive chunks totals 18,874,373 bytes, below 19 MiB (19,922,944 bytes). Repository defaults fit below the 2 MiB live default. Overflow-safe configuration must still validate the exact negotiated frame and receive values before active mutation.
- Each frame uses the injected sample of the callback that completes it. Equal-sample split/coalesced delivery is equivalent; genuinely later split samples may produce only documented later time-based results. Continuation delay does not rewrite the frame sample.
- A policy timeout defers terminal commit only for already-owned complete suffix frames sampled before that deadline. Equality or later samples do not defer. A matching conservative acceptance can commit independent of timeout/continuation queue order; exhaustion, partial-only input, or a violation commits the recorded timeout without rearm. Physical terminal, explicit cancellation, and shutdown retain immediate safety precedence.

### Prior architecture and API findings

- Conservative V1 acceptance is observable and implementable without a generation field: one pending offer, componentwise-lower acceptance attributed to that offer, and no-pending acceptance treated as repetition.
- Correlation uses the exact installation-ID/optional-Bundle-ID tuple. Exact live duplicates are rejected; different or missing Bundle variants are separate unauthenticated, non-inheriting rows.
- There is no reconnecting state. Returning connections use ordinary negotiating state; recent presentation remains bounded and unauthenticated.
- Same-core handoff is synchronous and reentrant, reserves one of 16 provisional/negotiating/active/disconnecting slots, installs the handler before transfer success, preserves coalesced input, retains the original decoder/callback/terminal owner, and rolls back to admission cleanup on failure.
- Recent rows remain capped at 64 with deterministic eviction, one manager expiry wake, generation checks, and zero shutdown ownership. UI delivery remains latest-only and bounded to 16 owned plus 64 recent rows.
- Inbound and downlink sequence commit points, queue/token/mailbox limits, Control reservation, Event-lane drop-summary handling, and content-free telemetry remain explicit and finite.
- Decoder progress and receive control are narrow platform-neutral internal Core seams. Viewer retains policy, scheduling, persistence, UI, and lifecycle. No supported SDK API, wire schema/version, raw Network.framework owner, decoder owner, nested manifest, entitlement, database, third-party runtime dependency, or second harness is introduced.

## Verdict

**Approved for the architecture/API artifact dimension.** The Round 5 exception is explicit and test-owned, and no unresolved architecture or API contradiction remains in the current artifacts.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**
