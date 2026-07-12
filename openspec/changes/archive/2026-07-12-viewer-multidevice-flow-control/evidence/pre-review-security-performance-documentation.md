# Pre-Implementation Review: Security, Performance, and Documentation

## Scope and Verdict

This lightweight artifact-only review read `AGENTS.md` and every current artifact under `openspec/changes/viewer-multidevice-flow-control`: change metadata, README, proposal, design, capability specification, task plan, and pre-implementation validation evidence. It also compared the proposed active-session limits and diagnostics with the already specified SDK-side active pump where that established a relevant protocol precedent. No production or test source was modified, and this report is the only added file.

The change has a strong bounded-session foundation: negotiating plus active ownership is capped at 16, the existing 32-owner admission bound remains independent, both business queues have count and byte limits, preferences have finite record counts, Control capacity is reserved, UI publication is latest-only, and idle work uses no recurring timer. Event history, export, control composition, performance charts, background operation, cloud transport, and public API changes are also excluded clearly.

Four security and resource-accounting gaps remain in the artifacts. In particular, an unauthenticated App identifier is currently allowed to replace a healthy logical route, recently disconnected rows are outside every count bound, and negotiated business rates do not bound the CPU work caused by a noncompliant peer.

**Exact unresolved actionable finding count: 4 — 1 High, 2 Medium, and 1 Low.**

**Approval withheld.** Resolve all four findings, strictly revalidate the artifacts, and obtain a fresh zero-finding pre-implementation review before modifying production or test source.

## Findings

### NW-MFC-SPD-001 — High — An unauthenticated route claim can replace a healthy session and inherit its trusted presentation and downlink routing

**Evidence**

- App authentication, certificate pinning, and pairing-code secrecy are explicit non-goals (`design.md:20-26`). The foundation also treats the pairing code as a nearby-visible selector, not a secret or peer identity proof.
- Despite that trust model, the design calls the App installation ID the routing authority and keys a logical route by installation ID plus optional Bundle ID (`design.md:38-40`; `spec.md:27-31`). Both fields are peer-provided Hello data with syntactic validation, not cryptographic proof of the App.
- A second connection presenting the same values may negotiate, atomically replace presentation ownership, and close the healthy old session without a route-specific operator decision (`design.md:42`; `spec.md:33-37`).
- The route retains nickname and stable selection, while future downlink Events are targeted to whichever session currently owns that logical route (`design.md:68-72,90-94`; `spec.md:101-116,177-193`). The UI has no required statement that App identity and nickname continuity are unauthenticated.
- The ordinary approval preference does not solve the default-automatic case and is not specified as an authenticated same-route replacement decision.

**Impact**

A nearby protocol-capable peer can copy a visible or previously observed installation ID and Bundle ID, complete ordinary policy negotiation, disconnect the legitimate active App, appear under its existing local nickname, and become the destination of later route-targeted downlink Events. This creates targeted denial of service, operator deception, and possible Event-content disclosure. A fresh session epoch prevents stale-frame replay inside a connection but does not authenticate the route claim that selects the connection.

**Required remediation**

1. State normatively that installation ID, Bundle ID, alias, and nickname are correlation and presentation values only and never authenticate an App.
2. Do not automatically replace a live route solely from those values. A safe V1 default is to reject the candidate until the old session is terminal. If seamless live replacement is essential, require an explicit route-specific operator confirmation that presents the new connection as unauthenticated and cannot be satisfied by nickname continuity alone.
3. Specify that queued or pending downlink values owned by the old connection/epoch are cleared or terminally dropped and are never reassigned to a replacement connection. A later send must be a new local submission against the newly selected session.
4. Require the workspace to label App identity as unauthenticated and to avoid presenting a nickname, Bundle ID, installation alias, or “reconnecting” state as identity proof.
5. Add deterministic spoof tests covering same installation ID, same/missing/spoofed Bundle ID, auto-accept, approval enabled, attempted live replacement, downlink queue ownership, and preservation of the legitimate session.

### NW-MFC-SPD-002 — Medium — Recently disconnected routes and their expiry work are outside every finite runtime bound

**Evidence**

- The 16-entry limit covers only policy-negotiating and active sessions (`design.md:30-32`; `spec.md:3-13`).
- Every terminal route may retain a reconnect row for 30 seconds, but neither design nor specification limits the number of distinct rows (`design.md:42-44`; `spec.md:27-31`). A reconnect replaces only the row for the same route.
- A peer can cycle through distinct installation IDs and Bundle IDs, so the active-session bound does not bound the number of rows created during one 30-second window.
- Those rows feed the sidebar and main-model snapshot, making both retained presentation state and snapshot size potentially unbounded (`design.md:86,90-94`; `spec.md:153-179`).
- Expiry is described as one-shot work, but ownership is inconsistent: a disconnected row intentionally retains no session, while the scheduling requirement lists reconnect expiry among per-session wake reasons (`design.md:44,80`; `spec.md:130-145`). The artifacts do not state whether one manager wake or one task per row is retained.

**Impact**

Sequential connection churn can accumulate route keys, presentation values, timestamps, UI rows, expiry bookkeeping, and main-actor snapshot work independently of the 16/32 connection bounds. The 30-second TTL limits lifetime but not cardinality or allocation rate. A nearby peer can therefore amplify memory, scheduling, and UI work without ever exceeding concurrent session capacity.

**Required remediation**

1. Add an exact runtime-wide maximum for reconnect/recent-disconnect rows, with deterministic oldest-first eviction and a clearly documented relationship to the 16 session and 32 admission bounds.
2. Require one manager-owned replaceable one-shot expiry wake for the entire bounded row collection, not one task or retained session owner per row.
3. Bound the complete manager snapshot by active/negotiating entries plus the recent-row cap and publish only that bounded value through the latest-only coalescer.
4. Define exact cleanup on runtime generation change, identity reset, window termination, explicit disconnect, replacement, and row eviction.
5. Add churn tests that create many distinct routes within 30 seconds, prove the cap and deterministic eviction, prove one expiry wake, and show that another active device and the MainActor remain responsive.

### NW-MFC-SPD-003 — Medium — Queue and token limits do not bound active ingress decoding or system-message CPU work from a noncompliant peer

**Evidence**

- Effective token buckets limit Viewer uplink delivery and downlink sending (`design.md:74-80`; `spec.md:130-151`). They do not limit bytes or completed frames decoded from the network before an Event enters the bounded uplink queue.
- Per-session queues bound retained memory, but a peer can continuously overflow them and force decode, route, sequence, TTL, priority, counter, drop-summary, telemetry, and scheduling work. The artifacts do not say that sending above an accepted App-uplink rate is rejected, backpressured, or subject to a finite burst budget.
- Policy, close, and protocol-defined drop summaries bypass business rate tokens. Outbound retention is coalesced, but no inbound per-turn allowance limits valid drop summaries or other allowed system frames (`design.md:76-84`; `spec.md:130-169`).
- “Bounded quanta before yielding” has no normative count/byte values and applies to scheduled due work, while the same-core decoder may complete multiple frames from one receive callback (`design.md:80`; `spec.md:134`).
- The isolation goal says a full or invalid device cannot stall another device (`design.md:11-18`; `spec.md:15-19`), but independent serial executors do not prevent one or sixteen peers from consuming shared CPU continuously.
- The existing SDK active-pump specification already treats completed frames per receive callback, incoming retained bytes including in-flight work, publications/expiries per turn, and active work-limit termination as separate hard bounds. The Viewer artifacts do not define the corresponding receiver-side contract.

**Impact**

Memory remains finite, but CPU, wakeups, decoding, telemetry publication, and drop-summary churn can track an attacker's network rate rather than the negotiated flow policy. This undermines the product's power-saving goal and the promise that one device cannot delay another. A flood can also keep an otherwise business-paused session permanently active without violating any stated retained-memory bound.

**Required remediation**

1. Define validated default and hard maxima for completed frames/records and decoded bytes per receive callback, incoming publications/expiries per service turn, and system/drop-summary messages per turn.
2. Define whether accepted App-uplink rate is a cooperative sender contract or only a Viewer delivery rate. If it is a sender contract, enforce an overflow-safe finite burst allowance and terminate sustained violations. In either case, retained queue overflow must not permit unbounded decode/service work.
3. Require the connection core to yield or close with a closed local `activeWorkLimitExceeded`/ingress-overflow category when a quantum is exceeded, without partially committing sequence or a batch.
4. Bound task ingress so a signal or receive storm retains at most one scheduled routing task plus one coalesced successor, and ensure no immediate retry loop occurs while a queue or mailbox remains blocked.
5. Add deterministic malicious-peer tests for tiny-frame batches, oversized record counts within a frame, sustained business traffic above policy, drop-summary storms, zero-rate sessions, and 16-session contention while an unaffected device negotiates, transfers, and disconnects within a fixed work bound.

### NW-MFC-SPD-004 — Low — Content-free telemetry does not yet cover logs, errors, reflection, or the final privacy-manifest decision

**Evidence**

- Event queues and effective policy are memory-only, and session snapshots correctly exclude Event content, metadata values, pairing code, endpoints, TLS material, raw bytes, and arbitrary transport errors (`design.md:82-88`; `spec.md:153-175,195-210`).
- Those prohibitions apply to snapshots/telemetry. The new session terminal categories, downlink validation failures, persistence repair, descriptions, reflection, and any logging are not normatively prohibited from retaining or rendering Event type/content, metadata values, keep-latest keys, route identifiers, Bundle IDs, policy/queue values, or underlying peer/system errors.
- The change adds persistent logical-route nickname records keyed by peer installation identity and Bundle-ID preferences in `UserDefaults`, but the artifacts do not require a final privacy-manifest assessment explaining whether the existing linked Device ID and UserDefaults declarations remain sufficient (`design.md:54-64`; `spec.md:78-99`; `tasks.md:24-30`).
- Task 5.4 requests documentation of memory-only behavior and failure categories but does not explicitly require safe diagnostic/reflection coverage or the privacy rationale.

**Impact**

An implementation can satisfy “no Event history” while still leaking content through debug descriptions, interpolated errors, logs, UI terminal text, or persistence-repair diagnostics. It can also change what identifiers are retained without recording why the existing Viewer privacy manifest remains correct. These are avoidable documentation and test ambiguities at a boundary that will later carry arbitrary application data.

**Required remediation**

1. Require every new error, terminal category, description, debug description, interpolation, reflection path, and log to derive only from a closed local code and to exclude Event type/content, metadata values, queue keys, route/installation/Bundle IDs, nicknames, rates, queue values, endpoints, certificate data, raw bytes, peer text, and underlying errors.
2. State that Event drafts, encoded payloads, queue keys, session epochs, and active queue state are absent from `UserDefaults`, logs, analytics, clipboard, exported data, UI state, and post-terminal retained rows.
3. Add a privacy-manifest review and built-product inspection to Tasks 5.4/5.5. Record whether the existing linked Device ID and UserDefaults reason cover the bounded route/nickname preferences and why no new collected-data or required-reason declaration is needed.
4. Add deterministic description/reflection/presentation tests plus source and packaged-resource checks; do not rely only on the snapshot model test.

## Verified Strengths and Non-Findings

- Negotiating plus active session ownership is synchronously capped at 16, while the foundation admission owner remains capped at 32 through asynchronous cleanup. A rejected 17th handoff creates no session task or row.
- The existing connection core, callback, decoder, terminal gate, and opaque handle remain the sole transport owner. No raw Network.framework object crosses into Viewer application state.
- Per-session queues are independently capped at 5,000 Events and 16 MiB, with negotiated single-Event validation. Sixteen sessions therefore produce a finite, derivable business-queue maximum, and the design already calls for aggregate-bound testing.
- Requested/effective flow policy is separated correctly. One offer is in flight, desired edits are latest-only, exact accepted values cannot exceed or differ from the current V1 offer, and zero pauses only business traffic.
- Bundle-ID policy and nickname persistence is versioned and capped at 256 records each, uses deterministic LRU eviction, rejects malformed/nonfinite values, and keeps effective policy, Event payloads, session epochs, queue state, and reconnect state out of persistence.
- Control/mailbox reservation, one coalesced local drop summary, saturating counters, latest-only UI publication, and no recurring idle timer are appropriate foundations once ingress work and reconnect-row cardinality are also bounded.
- Route, epoch, direction, source/target, codec/schema, sequence, payload size, and receiver-local TTL validation are correctly required before delivery. Invalid input closes one session without coupling another.
- Event acceptance truthfully makes no remote delivery, processing, persistence, acknowledgement, replay, or guaranteed-delivery claim.
- Event history, timeline/details, search/filter, SQLite/local-store settings, export, control composition, performance charts, background operation, cloud service, internet rendezvous, new transport, public API expansion, and a second shell harness remain explicitly outside this change.
- The pre-implementation artifacts are complete, English-only, strictly valid, and recorded before source work. Task 1.2 correctly remains open pending review remediation.

## Required Artifact Gate

Revise the proposal/design/spec/tasks to close all four findings, update the saved pre-implementation validation after the revisions, and obtain fresh architecture/API, correctness/testing, and security/performance/documentation artifact reviews. Production or test implementation must not begin until every review reports zero unresolved actionable findings.
