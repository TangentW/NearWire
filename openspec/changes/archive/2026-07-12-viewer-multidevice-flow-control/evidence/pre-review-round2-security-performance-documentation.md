# Pre-Implementation Review Round 2: Security, Performance, and Documentation

## Scope and Verdict

This second lightweight artifact-only review re-read every current `viewer-multidevice-flow-control` artifact and the Round 1 security/performance/documentation report after remediation. It verified the four prior findings against the proposal, design, normative capability specification, task plan, and refreshed pre-implementation validation evidence, then audited the remediated limits for new trust, resource, scheduling, privacy, and documentation contradictions. No production or test source was modified; this report is the only added file.

All four Round 1 findings are materially resolved. Live duplicate correlation claims can no longer replace an owned connection, pending downlink work is bound to an exact connection and epoch, recent rows/UI snapshots/expiry ownership are finite, active ingress now has explicit byte/frame/record/system/service limits, and diagnostics plus privacy-manifest evidence are explicitly owned.

One new availability defect remains: the artifacts close a session when a receive callback contains more than the per-callback service quantum, even when every frame is valid and the same traffic is permitted by the time-based token bucket. Because TCP receive coalescing is not controlled by the peer or protocol, validity currently depends on how Network.framework groups bytes. The default system-message callback limit of 32 directly contradicts the permitted burst of 128.

**Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, and 0 Low.**

**Approval withheld.** Resolve the coalescing-dependent work-limit behavior, strictly revalidate the artifacts, and obtain a fresh zero-finding artifact review before production or test implementation begins.

## Round 1 Finding Disposition

| Round 1 finding | Round 2 disposition |
| --- | --- |
| `NW-MFC-SPD-001`: unauthenticated route claims could replace a healthy session and inherit nickname/downlink routing | **Resolved.** Peer-declared installation ID, Bundle ID, metadata, alias, and nickname are now explicitly unauthenticated correlation hints. A duplicate key is rejected while its original connection is provisional, negotiating, active, or disconnecting, in both admission policies. Reconnection begins only after exact handle cleanup releases the old slot. Downlink queue state is bound to the internal connection ID and epoch, is terminally cleared, and never migrates to a later correlation match (`design.md:40-60`; `spec.md:39-63`; `tasks.md:8-10,26-28`). The workspace must label continuity as unauthenticated. |
| `NW-MFC-SPD-002`: recent rows and expiry work were unbounded | **Resolved.** Recent rows are capped at 64, expire after 30 seconds, evict deterministically by oldest disconnect time with correlation-key tie-breaking, and share one manager-owned replaceable wake. One wake services at most the complete 64-row bound; snapshots contain at most 16 owned rows plus 64 recent rows; shutdown owns rows and wake cleanup (`design.md:46-60,112,118`; `spec.md:41-63,212`; `tasks.md:9,26,28`). |
| `NW-MFC-SPD-003`: queue/rate limits did not bound ingress CPU and system-message work | **Partially resolved; one new contradiction remains.** The artifacts add a two-second App-uplink sender-contract bucket, zero-rate enforcement, byte/frame/record/system limits, a separate system-message bucket, finite publication/expiry/service turns, one task plus one coalesced successor, no blocked immediate retry, and malicious-peer isolation tests (`design.md:104-112`; `spec.md:171-206`; `tasks.md:16,27-28`). However, callback overflow currently terminates based on transport coalescing rather than deferring valid remaining work; see `NW-MFC-SPD2-001`. |
| `NW-MFC-SPD-004`: content-free telemetry omitted logs/errors/reflection and privacy evidence | **Resolved.** Every new diagnostic surface must derive from a closed code and exclude Event/route/identity/rate/queue/peer/system detail. Event drafts, payloads, queue keys, epochs, contents, and effective policy are excluded from persistence and unintended surfaces. Tasks require description/reflection/presentation tests, an English privacy rationale, and built privacy-manifest inspection covering Device ID and UserDefaults declarations (`design.md:114-128`; `spec.md:208-238`; `tasks.md:29-30`). |

## Finding

### NW-MFC-SPD2-001 — Medium — Valid traffic can be terminated solely because TCP coalesces it into one receive callback

**Evidence**

- The remediation introduces default per-callback limits of 64 KiB, 64 completed frames, 512 Event records, and 32 system messages, with hard maxima of 1 MiB, 256 frames, 2,048 records, and 128 system messages. The first callback/frame that would exceed one of those limits closes with `activeWorkLimitExceeded` (`design.md:111`; `spec.md:187`).
- The same requirement permits a separate system-message rate of 64 per second with a burst of 128 (`design.md:111`; `spec.md:187`). Thirty-three valid system messages are therefore inside the permitted time-based burst but outside the default callback limit when Network.framework delivers them together.
- The accepted App-uplink sender contract similarly permits a two-second burst. At elevated valid requested rates, more than 64 independently valid Event frames may be in flight and coalesced into one receive chunk even though their total Event-record count remains within available sender-contract tokens (`design.md:107`; `spec.md:185-187`).
- TCP and Network.framework callback boundaries are not wire-message boundaries. The same ordered bytes may arrive as several callbacks or one callback. The current contract accepts the split form but can close the coalesced form.
- A service quantum is meant to bound uninterrupted CPU work and yield fairly. Treating the quantum as a protocol violation instead makes transport segmentation observable and allows ordinary scheduling/network delay to terminate a conforming session.
- The artifacts do not require cross-limit validation between receive-chunk size, frame limit, negotiated maximum Event/frame, batch count, sender/system burst capacity, and the callback work limits. They also say internal configuration may lower callback limits without defining a coherent minimum (`design.md:111`).

**Impact**

A valid SDK peer can be disconnected nondeterministically based on kernel/network coalescing, host scheduling delay, or an otherwise permitted burst. The failure is especially likely for many small frames or system messages, exactly the cases the work limit is intended to service safely. It produces false `activeWorkLimitExceeded` terminal state, breaks device isolation/reliability, and makes tests pass or fail depending on arbitrary receive chunking.

This is not an argument for unbounded callback work. The byte ingress, retained decoder state, task count, time-based sender contract, and per-turn CPU service must all remain finite; the defect is using the service quantum as a wire-validity boundary instead of a scheduling boundary.

**Required remediation**

1. Separate hard ingress-retention/protocol bounds from per-turn service quanta. A valid callback containing more than one turn's frames/records/system messages must pause decoding after the quantum, retain only the bounded unconsumed suffix, and schedule at most one coalesced continuation on the same core executor. It must not request or retain another receive chunk until the suffix is serviced.
2. Close only when a single frame/batch violates wire, route, sender-contract, or hard retained-input limits; when total bounded retained input cannot fit; or when the time-based Event/system bucket is actually exceeded. Do not close merely because several individually valid frames share a callback.
3. Define cross-limit validation before active mutation: the retained raw-input byte bound must fit one configured receive chunk and one maximum legal encoded frame; record work limits must fit one legal maximum batch or service it atomically without partial commit; and hard limits must remain within existing Core frame/decoder bounds.
4. Make the system-message callback/turn quantum coherent with the 128-message burst. A burst may require several bounded turns, but its acceptance must not depend on callback splitting.
5. State exact commit behavior across continuation turns. Earlier whole frames may remain committed, the unprocessed suffix remains ordered and charged, a single Event batch remains atomic, terminal close invalidates the continuation, and no later callback can overtake retained input.
6. Add deterministic equivalence tests that feed the same valid byte sequence as one coalesced callback and many split callbacks. Cover 33–128 system messages within the permitted burst, more than 64 small Event frames within ingress tokens, a maximum legal Event frame, a maximum legal 256-record batch, terminal racing a retained suffix, and another session progressing between continuation turns.

## Verified Security, Performance, Privacy, and Documentation Boundaries

- The 16-slot registry now explicitly includes provisional, negotiating, active, and disconnecting ownership through exact handle cleanup. A 17th handoff and a live same-key duplicate are rejected before creating an unbounded owner/task family.
- Same-core attachment is synchronous and reentrant, preserves coalesced post-Hello input, retains one decoder/protocol/sequence/terminal executor, rolls back provisional state, and holds no manager lock across reentrant core operations.
- Peer identity hints are truthfully unauthenticated. They neither authorize live replacement nor retarget existing Event work, and UI continuity is presentation-only.
- Recent state is finite: 64 rows, one manager wake, at most 64 removals per wake, deterministic eviction, generation checks, bounded snapshots, and zero row/wake ownership at shutdown.
- Policy deadlines are non-resetting and monotonic. One V1 offer is pending, conservative acceptance is correlated by ordered phase, equality is timeout, and terminal/acceptance winners are serialized on the core queue.
- Inbound sequence commits are atomic per valid frame before local expiry/overflow, while malformed or wrong-route input advances nothing. Downlink sequence, queue removal, fairness, tokens, and telemetry commit only with atomic mailbox ownership; terminal cleanup never migrates pending work.
- The two 5,000-Event/16-MiB queues per session, 16-session cap, secure-mailbox reservation, saturating counters, queue service limits, sender-contract token bucket, and blocked-work no-retry rule establish finite retained memory and scheduling ownership.
- Requested versus effective policy remains distinct. Zero business rate preserves Control, system telemetry, TTL, and cleanup progress.
- Preferences remain versioned, bounded to 256 policy and 256 nickname records, deterministically evicted, safely repaired, and isolated from transport callbacks. Effective policy, Events, epochs, queues, and recent state remain memory-only.
- New diagnostic, logging, reflection, clipboard, analytics, export, UI, and persistence exclusions are explicit and test-owned. Privacy-manifest rationale and packaged-resource inspection are mandatory evidence rather than an assumption.
- Event history, search/filter, local-store UI, export, control composition, performance charts, background execution, cloud service, internet rendezvous, new transport, public Core/SDK API, and a second test script remain clearly excluded.
- The remediated artifacts were strictly revalidated with unchanged OpenSpec, diff, and English gates before source implementation. Task 1.2 appropriately remains incomplete pending fresh zero-finding reviews.

## Required Artifact Gate

Revise the design, capability specification, tasks, and pre-implementation validation record to resolve `NW-MFC-SPD2-001`. Then obtain a fresh artifact review round across architecture/API, correctness/testing, and security/performance/documentation. Production and test source implementation must not begin until all dimensions report zero unresolved actionable findings.
