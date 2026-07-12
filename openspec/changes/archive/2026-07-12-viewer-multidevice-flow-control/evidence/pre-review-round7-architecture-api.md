# Pre-Implementation Review Round 7 — Architecture and API

Date: 2026-07-13

## Scope

This fresh artifact-only review re-read `AGENTS.md` and every current artifact under `openspec/changes/viewer-multidevice-flow-control`. It rechecked all prior architecture/API findings and specifically audited the amended 16-slot ownership statement and evidence plan across proposal, design, normative specification, and tasks. No production or test source was modified; this report is the only added file.

## Verification

### Exact 16-slot ownership

The ownership bound is now consistent at every artifact level:

- The proposal bounds every mixture of provisional, negotiating, active, and disconnecting App owners to 16 through exact cleanup while keeping the admission layer's independent 32-owner bound (`proposal.md:7`).
- The design goal and session-manager decision name the same four lifecycle phases. Capacity is claimed synchronously during transfer, a provisional reservation consumes a slot, and disconnecting retains its slot until the original handle finishes cleanup (`design.md:13,32,36,48`).
- The normative requirement and capacity scenario explicitly apply the bound to any pure or mixed set of provisional, negotiating, active, and disconnecting owners. A 17th handoff creates no session task or row, returns to original admission cancellation ownership, and cannot disturb the first 16 (`specs/viewer-multidevice-flow-control/spec.md:5-13`).
- Duplicate claims also treat provisional as owned, so two same-key transfers cannot bypass correlation uniqueness during attachment (`spec.md:41-45`).
- Tasks require exact pure and mixed four-state unit coverage through cleanup plus a barrier-controlled 16-owner mixed integration registry and 17th rejection (`tasks.md:26,28`).

No phase can release capacity early merely by leaving active state, and recent rows remain outside but separately bounded from the 16 live-owner slots.

### Same-core and receive-control architecture

- Transfer remains one synchronous reentrant transaction. It reserves provisionally, releases the registry lock before core attachment, installs the handler inline before transfer succeeds, preserves coalesced post-Hello input, and rolls back to admission cleanup ownership on failure.
- The original connection core remains the sole decoder, wire-phase, policy-transaction, sequence, and terminal executor. No Network.framework object, callback owner, mutable decoder owner, or unbounded frame stream crosses into session/UI state.
- Core decoder progress is finite and distinguishes `pausedOnCompleteFrame`, ordinary `needsMoreBytes`, and ordinary `drained`. The recorded-policy-timeout partial/drained exception closes without resume and is separately test-owned.
- One synchronous generation-bound receive-pause token prevents eager rearm and composes with exactly one suffix and continuation. Detach-before-resume, immediate callback, stale generation, resume/terminal winner orders, and zero-residue terminal cleanup remain explicit.
- Input accounting remains valid: a 16 MiB payload plus 5-byte frame overhead plus two 1 MiB receive chunks is 18,874,373 bytes, below the 19 MiB hard cap. Defaults remain below 2 MiB, subject to mandatory overflow-safe cross-field validation.

### Protocol, identity, and bounded-resource regression

- V1 policy acceptance remains implementable without a transaction field: at most one pending offer, componentwise conservative acceptance attributed to that offer, and acceptance with no pending offer treated as an observable repeat.
- Frame-completion receipt samples and timeout/suffix arbitration are total. Equal-sample callback partitioning is equivalent; later completion samples may produce only documented later time-based outcomes.
- Correlation uses the exact installation-ID/optional-Bundle-ID tuple. Exact live duplicates are rejected in both admission modes; different or missing Bundle variants are separate unauthenticated rows that inherit no nickname, selection, session, or downlink ownership.
- Returning devices use ordinary negotiating state; no reconnecting state remains. Recent rows stay capped at 64 with deterministic eviction, one manager expiry wake, generation checks, and zero shutdown ownership.
- Downlink work remains bound to one exact connection and epoch. Inbound/downlink sequence commit, queue/token/mailbox bounds, Control reservation, Event-lane drop summaries, finite service quanta, content-free telemetry, and memory-only Event/effective state remain coherent.

### Repository and API boundary

The added decoder progress, retained-byte observation, and secure-channel receive token are narrow platform-neutral internal Core seams with Core tests. Viewer retains policy, scheduling, persistence, UI, and lifecycle. The change introduces no supported SDK API, wire schema/version, transport owner, nested manifest, database, entitlement, third-party runtime dependency, or additional shell harness.

## Verdict

**Approved for the architecture/API artifact dimension.** The four-state 16-slot ownership and mixed-state evidence are complete, and no unresolved architecture or API issue remains in the current artifacts.

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**
