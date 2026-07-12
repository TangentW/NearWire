# Pre-Implementation Correctness and Testing Review — Round 3

## Scope

Reviewed the newly revised `sdk-public-connect` proposal, design, seven capability deltas, and task plan without modifying planning or production source. The review first re-verified all three Round 2 findings, then independently traced the synchronous phase gate, attempt target generations, task cancellation and shutdown precedence, session lifetime creation, one-shot terminal observation, transfer and actor commit, weak-owner deinitialization, process-lease ownership, preflight state behavior, Keychain transcripts, constant-space record sizing, deterministic barriers, and retain-graph evidence.

## Round 2 Remediation Verification

| Round 2 finding | Round 3 status | Evidence |
| --- | --- | --- |
| 1. Admission could miss outer shutdown after phase suspension | Resolved | Admission now receives the attempt's synchronous content-free authorization gate and a closed observer result, checks admission state, Task cancellation, and the gate before and immediately after observer suspension, and explicitly covers delayed actor cancellation delivery (`design.md:56-67,113-117`; `specs/sdk-session-admission/spec.md:3-19`; `specs/sdk-public-connect/spec.md:86-104`; `tasks.md:20,23`). |
| 2. Terminal observation had no unique owner or complete outcomes | Resolved for one-wait ownership; a new cross-domain linearization gap remains | One `SDKSessionLifetime` now creates one termination value, and one coordinator starts and owns the sole wait, lease, terminal flag, and release gate before attachment. Admitted session, attachment, and active handle share that lifetime; shutdown and deinitialization do not re-register a wait (`design.md:119-139`; `specs/sdk-session-admission/spec.md:9-24`; `specs/sdk-active-event-pump/spec.md:3-20`; `specs/sdk-public-connect/spec.md:106-122`; `tasks.md:21-24`). Finding 1 below concerns how terminal is atomically ordered against transfer and actor commit, not duplicate observation ownership. |
| 3. One fixture did not prove every queue-to-wire expansion | Resolved | The network maximum is now independent of queue-accounting encoding and is defined as the fixed validated deterministic-content bound plus an exact non-content V1 record maximum. The plan requires a structural proof over every `JSONValue` case, production-encoder adversarial/generated properties, exact/one-over downstream limits, hostile incoming coverage, and peak-retention evidence (`design.md:35-54,163-170`; `specs/sdk-public-connect/spec.md:27-48`; `tasks.md:10-11,33`). This matches current production behavior: `JSONValue.validate` bounds deterministic content bytes and `WireEventRecord` embeds that value directly (`Core/Sources/NearWireCore/Event/JSONValue.swift:97-189,320-329`; `Core/Sources/NearWireTransport/WireEventPayloads.swift:96-129`). |

## Findings

### 1. HIGH — Terminal, active transfer, and actor commit still lack one shared linearization gate

**Evidence**

- The attempt lock owns cancellation reason, target generation, authorization, and active-transfer commit (`design.md:56-67`; `specs/sdk-public-connect/spec.md:86-95`).
- The terminal coordinator separately owns the terminal flag and release gate (`design.md:121-125`; `specs/sdk-public-connect/spec.md:106-110`). Actor owner installation and connected publication are isolated by the NearWire actor (`design.md:127-139,153-155`).
- The normative table correctly distinguishes terminal-before-transfer, transfer-before-terminal, terminal-after-transfer-before-actor-commit, and actor-commit-before-terminal (`design.md:127-139`; `specs/sdk-public-connect/spec.md:112`). However, no operation is specified that linearizes a transfer or actor-commit claim against the coordinator's terminal latch under the same lock.
- Barriers before and after transfer, actor commit, and terminal delivery make broad orderings deterministic, but they do not remove a check-then-commit window inside an implementation (`design.md:69-84`; `tasks.md:17,23`).

For example, an implementation can satisfy every stated component rule yet execute:

1. active transfer commits;
2. the actor checks that the coordinator is not terminal;
3. the coordinator latches terminal and releases the exact lease;
4. the actor installs the connected owner, publishes connected, and returns success.

Terminal occurred before actor commit, so the normative row requires a mapped pre-return failure, but the uncoordinated check permits the actor-commit-first result. The equivalent race exists between reading a nonterminal coordinator and committing active transfer.

**Impact**

The pending call's success or failure, connected publication, and lease availability can depend on scheduling between independent locks rather than the specified winner table. In the example above, another instance may claim the released process lease while the old actor is still committing a connected public owner for a terminal core. Exact-token release protects the new lease from stale clearing, but it does not make the old success result truthful.

**Required remediation**

Add one lock-linearized session transition gate shared by the terminal coordinator and the public transfer/actor-commit path. At minimum it must atomically support:

- terminal versus active-transfer claim;
- terminal versus actor-connected-commit claim; and
- idempotent terminal delivery after either claim.

The actor must synchronously win the coordinator's actor-commit claim inside the same actor turn and before installing the owner or publishing connected. The terminal Task must latch terminal through the same gate before releasing the lease or sending its callback. State whether the attempt transfer gate is merged into this coordinator gate or define a fixed lock order and one composite operation that cannot observe an intermediate winner. Also define the result when Task cancellation and terminal contend before transfer; shutdown must continue to override both until actor commit.

Place test hooks at the actual gate claims, not only around their callers. Add both-winner tests that pause after a losing precheck but before mutation and prove the stale mutation is impossible. Each row must assert the connect result, actor commits, terminal flag, target generation, handle cancellation count, one wait, one release, callback count, and later-claim eligibility.

### 2. HIGH — Failures before successful admission have no explicit lease-release owner

**Evidence**

- The attempt owns the exact lease through the non-cancellable identity worker and admission completion. The terminal coordinator is created only immediately after admission successfully returns (`design.md:86-101,119-125,141-145`; `specs/sdk-public-connect/spec.md:59-65,106-110,147-151`).
- The modified lease capability says the attempt retains the handle until its worker or admission completes, then says only the post-admission terminal coordinator invokes release after terminal (`specs/sdk-process-connection-lease/spec.md:3-9`). It never states who explicitly releases after identity failure, stale identity completion, discovery failure, phase rejection before core construction, or admission failure before an admitted lifetime is returned.
- The public-connect lease requirement says every path releases “after terminal” (`specs/sdk-public-connect/spec.md:147-151`). Identity and pre-core discovery failures have no session terminal value, and the task plan only assigns exact ownership to the post-admission coordinator (`tasks.md:19-25`).
- The low-level handle has defensive deinitialization release, but relying on incidental ARC destruction does not define release ordering relative to exact slot cleanup, pending error completion, retry, or injected release failures (`openspec/specs/sdk-process-connection-lease/spec.md:39-63`).

**Impact**

A literal implementation can retain the process lease permanently after an ordinary identity or discovery failure because no coordinator exists and the attempt is only told to retain, not explicitly release. A less literal implementation may drop the handle at an arbitrary point, causing a same-instance retry to observe process contention while the prior call is still cleaning up. These common pre-admission branches therefore lack the exact ownership and evidence applied to active-session cleanup.

**Required remediation**

Define two non-overlapping release regimes:

1. before an admitted lifetime is returned, the exact attempt/attempt-cleanup owner retains the lease until the identity or admission operation has fully completed, then explicitly invokes exact release once; and
2. after successful admission, one atomic handoff transfers the handle to the sole terminal coordinator, after which only that coordinator releases after core terminal.

Specify the handoff so cancellation or shutdown cannot make both owners release or make neither own the handle. Define slot/state and pending-call completion order around pre-admission release, while preserving fail-closed claim-exit/release-enter/release-exit semantics and no reacquisition promise after synchronization failure.

Add deterministic tests for identity hit failure, random/add/reread failure, stale identity result after shutdown, discovery failure, phase authorization rejection, and every admission error before lifetime return. Each must assert one exact release invocation after operation completion, no terminal wait/coordinator construction, prior-state preservation before discovering or one disconnected commit after discovering, no stale newer-token effect, and retry only after successful synchronization.

## Re-Traced Areas With No Additional Finding

- **Phase authorization:** the shared synchronous gate closes the delayed actor-cancel race and the observer result cannot authorize stale core/channel construction.
- **Task cancellation and shutdown:** preflight precedence is exact, task cancellation becomes stale only after active transfer, shutdown remains authoritative through actor commit, and connected commit plus success return are one actor turn (`design.md:21-33,56-67`).
- **Weak-owner deinitialization:** the revised active-pump capability removes permanent-core strong ownership, captures rate policy by value, requires weak owner-aware live operations, and tests the complete handle-cancel-to-terminal-to-release chain (`specs/sdk-active-event-pump/spec.md:5-25`; `tasks.md:22-24`).
- **State semantics:** pre-discovery failures preserve idle or prior disconnected; later failures disconnect once; shutdown is final; state streams remain latest-value rather than historical replay (`specs/sdk-public-connect/spec.md:5-25,134-145`; `specs/sdk-async-facade/spec.md:34-46`).
- **Keychain transcripts:** exact modern read/add dictionaries, protected-item skip/duplicate/skip, all initial and duplicate-reread failures, bounded call counts, and zero update/delete behavior are explicitly required (`design.md:86-103,163-170`; `tasks.md:12-13`).
- **Constant-space limits:** the fixed deterministic-content plus exact-record formula and structural/generated production-encoding evidence close the Round 2 representation gap without allocating a synthetic maximum payload.
- **Fail-closed runtime release:** successful synchronization is the only condition that promises reacquisition; claim-exit, release-enter, release-exit, repeated, and stale release remain covered (`design.md:141-145`; `tasks.md:25,30,33`).

## Review Status

**Unresolved finding count: 2 — 2 High. Correctness/testing approval is not granted.**

All three Round 2 findings are resolved in their original scope. The two findings above are new ownership/linearization gaps exposed by following the revised terminal coordinator across its boundaries.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Static cross-check against the current facade actor, state hubs, identity ordering, process lease, admission/core ownership, cancellation relay, one-shot termination observer, active-operation gate, queue accounting, deterministic content validation, wire Event encoding, and active-pump owner references.
