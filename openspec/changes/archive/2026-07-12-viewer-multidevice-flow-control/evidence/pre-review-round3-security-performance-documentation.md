# Pre-Implementation Review Round 3: Security, Performance, and Documentation

## Scope and Verdict

This third artifact-only review re-read the current `viewer-multidevice-flow-control` proposal, design, capability specification, task plan, validation record, and all Round 2 review reports. It checked the Round 2 callback-coalescing remediation against the existing Core decoder, secure-channel receive loop, and Viewer admission ingress. No production or test source was modified; this report is the only added file.

The revised artifacts correctly distinguish hard protocol/token/retention failures from finite scheduling quanta. They define bounded decoder pause/resume, one same-core continuation, original receipt-time token accounting, atomic paused-frame ownership, terminal invalidation, valid 33-through-128 system bursts, and split-versus-coalesced outcome tests. The exact-tuple duplicate rule, connection-bound downlink ownership, content-free diagnostics, memory-only Event handling, and built privacy-manifest evidence also remain closed.

One implementation-boundary contradiction remains. The artifacts require the connection core to yield with retained input while preventing the secure channel from retaining or delivering another callback, but the existing channel unconditionally rearms receive after its synchronous event handler returns. The proposal and tasks authorize only a decoder pause/resume seam, not the receive-credit/backpressure seam required to make the ordering and retained-memory claims true.

**Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, and 0 Low.**

**Approval withheld.** Resolve the receive-backpressure ownership gap, strictly revalidate the artifacts, and obtain a fresh zero-finding artifact review before production or test implementation begins.

## Round 2 Finding Disposition

### `NW-MFC-SPD2-001`: callback grouping changed validity — Semantically resolved, with one residual implementation-boundary defect

The normative model no longer closes merely because one callback exceeds a service quantum. Valid extra whole frames pause, remain ordered and charged, and resume through one same-core continuation; hard retained-input, wire/frame/batch, sender-contract, and system-bucket violations still close before the offending frame commits (`design.md:111-117`; `spec.md:185-193,212-233`). Continuation turns use the callback's original monotonic receipt sample, one maximum legal Event batch must fit the record quantum, a 128-message system burst may span four default turns, terminal state releases retained bytes, and tasks require split/coalesced equivalence plus maximum-frame, maximum-batch, system-burst, terminal-race, token-state, and multi-session fairness coverage (`tasks.md:8,16,27-28`).

Those changes resolve the Round 2 protocol-validity defect. Finding `NW-MFC-SPD3-001` below concerns the missing lower-layer ownership mechanism needed to implement those semantics without hidden queued input.

## Finding

### NW-MFC-SPD3-001 — Medium — Decoder-only pause cannot stop the secure channel from rearming receive

**Evidence**

- The proposal says this change adds only a platform-neutral bounded pause/resume decoder SPI (`proposal.md:8`). Task 2.1 likewise names the decoder and connection-core continuation but no secure-channel receive-credit, suspend, acknowledgement, or backpressure seam (`tasks.md:8`).
- The design says the decoder retains one bounded chunk/frame suffix, the core schedules one continuation, later bytes cannot overtake, and the core does not retain a second callback task (`design.md:111,115-117`). The normative requirement similarly permits at most one scheduled continuation plus one successor bit and requires continuation work to run before later receive input (`spec.md:187-193`).
- The current `SecureByteChannel` owns the receive loop. After it synchronously invokes `eventHandler(.received(data))`, it unconditionally calls `requestReceiveIfPossible()` and starts another driver receive (`Core/Sources/NearWireTransport/SecureByteChannel.swift:216-276`). Its event API carries bytes but no completion/credit with which the connection core can defer that rearm (`SecureByteChannel.swift:8-12,51-52`).
- Viewer forwards that event synchronously into `ViewerAdmissionConnectionCore.receive`, which serializes through `queue.sync` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:251-256,402-417`). If the core pauses and enqueues a continuation asynchronously so another session can progress, the synchronous handler returns and the channel is free to receive another chunk.
- A later receive may therefore be retained outside the decoder while a continuation is pending. Across multiple continuation turns, its core-queue block can also be enqueued before a later continuation and violate the stated no-overtake rule. Draining every turn before returning would avoid the second receive but would remove the required cooperative yield; blocking the channel callback until all turns finish would introduce an undocumented wait and ownership path.
- The stated retained-input bound of one receive chunk plus one maximum legal encoded frame does not explicitly include bytes held by the secure channel, callback ingress, or a later callback blocked on the core queue. Terminal cleanup consequently has no specified cancellation/charging oracle for that possible input (`design.md:111,115`; `spec.md:187,191`).

**Impact**

The design cannot currently prove all three required properties at once: finite per-turn CPU, strict byte ordering across continuation turns, and a complete retained-input bound. Depending on scheduling, a conforming implementation may process later input before an older suffix, silently retain memory outside the declared bound, or drain synchronously and defeat cross-session fairness. Terminal close may also release decoder bytes while another receive callback still owns unaccounted Data.

This does not invalidate the pause/resume decoder model. It means receive ownership must participate in the model instead of assuming the decoder alone controls when the transport requests more bytes.

**Required remediation**

1. Add a narrow internal secure-channel receive-credit/backpressure seam. The connection core must explicitly acknowledge that a delivered chunk is drained before the channel rearms receive, or explicitly suspend and resume receive through one idempotent bounded ownership token. Keep the raw Network.framework object and receive-loop ownership inside `NearWireTransport`.
2. Define one terminal-safe owner for the outstanding receive credit. Pause must retain exactly one decoder suffix and one continuation; terminal, decoder failure, attachment rollback, or shutdown must invalidate the continuation, release retained bytes, and resolve/cancel the receive credit exactly once without rearming.
3. Define the total retained-input formula across every layer: decoder partial-frame storage, unconsumed delivered bytes, secure-channel/callback-ingress Data, and any permitted pending chunk. Use overflow-safe configuration validation against the receive-chunk and encoded-frame hard bounds. If a pending next chunk is allowed instead of strict backpressure, bound it explicitly, include it in the memory limit, preserve its receipt sample, and prevent another rearm until it is consumed.
4. Preserve original monotonic receipt samples at the layer that first accepts each chunk. Specify which sample applies when a frame spans chunks, and ensure continuation scheduling delay neither refills sender/system buckets nor changes receiver-local TTL accounting for already accepted bytes.
5. Amend proposal impact, design, capability scenarios, and tasks to own this internal transport seam. Add deterministic tests with a controllable secure driver proving: receive is not rearmed while a suffix is paused; an immediate next completion cannot overtake; only one continuation/credit exists; the exact retained-byte maximum includes all layers; split and coalesced input with equivalent receipt samples has identical token/sequence/terminal state; a frame spanning chunks uses the stated receipt-time rule; and terminal racing pause leaves zero decoder bytes, pending callback Data, credits, continuations, and receive requests.

## Verified Security, Performance, Privacy, and Documentation Boundaries

- Exact duplicate rejection now uses the declared tuple of installation ID plus optional Bundle ID. A same-installation different/missing Bundle ID is a separate unauthenticated row and cannot inherit nickname, selection, session, or downlink ownership.
- Provisional, negotiating, active, and disconnecting owners share the finite 16-slot bound through exact handle cleanup. Recent rows remain separately capped at 64 with one bounded expiry owner.
- Downlink work remains bound to an exact connection ID and epoch, is cleared or terminally dropped, and never migrates through an unauthenticated correlation match.
- Policy acceptance now states the observable V1 rule for an indistinguishable lower response while one offer is pending. Requested and effective values remain distinct and terminal/deadline winners remain serialized.
- Hard retained-input, frame/batch, sender-contract, and system-message limits are separate from service turns. Event batches remain atomic and valid system bursts can span bounded turns.
- Queue count/byte limits, session count, mailbox reservation, saturating telemetry, one-shot scheduling, and latest-only main-model publication remain finite.
- New errors, descriptions, reflection, interpolation, and logs derive from closed codes and exclude peer, Event, route, policy, queue, TLS, endpoint, and raw-byte content.
- Event payloads, drafts, queue keys, epochs, and queue contents remain absent from persistence, UI state, recent rows, logs, analytics, clipboard, and export. Effective policy remains memory-only except for the bounded live snapshot.
- Task 5.5 still requires an English privacy rationale and inspection of the built manifest for existing Device ID and UserDefaults declarations; privacy evidence is not inferred from source alone.
- Event history, search/filter, local storage, export, control composition, performance charts, new public SDK API, wire changes, dependencies, entitlements, and a second harness remain outside this change.

## Required Artifact Gate

Revise the proposal, design, capability specification, tasks, and pre-implementation validation record to resolve `NW-MFC-SPD3-001`. Then obtain a fresh review round across architecture/API, correctness/testing, and security/performance/documentation. Production and test implementation must not begin until every review dimension reports zero unresolved actionable findings.
