# Post-Implementation Architecture/API Review — Round 1

## Scope

Reviewed the complete current uncommitted implementation diff against the active change's proposal, design, seven capability deltas, task plan, recorded evidence, tests, documentation, and the repository agent guide. The review focused on permanent-owner continuity, public/SPI boundaries, ownership and cancellation precedence, policy transaction ordering, cross-actor linearization, resource lifetime, and scope discipline. No production, test, specification, or task source was modified by this review.

## Findings

### 1. P1 / High — Owner shutdown can be lost during binding or policy negotiation

**Evidence**

- `NearWire.shutdown()` persists `.shutdown` and then invokes the generic outbound callback (`SDK/Sources/NearWire/NearWire.swift:237-245`), so the callback is only an edge notification for a persistent owner state.
- The callback reaches `receiveOutboundSignal`, which only latches `outboundWorkRequested` and calls the active drain scheduler (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:490-492,562-568`). That scheduler refuses to perform any owner observation unless the core is already `.active` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1177-1183`).
- A successful binding result moves the core to `.negotiatingPolicy`, resumes ingress, and consumes buffered policies, but never consumes a signal latched before result delivery and never performs a level-triggered owner-availability refresh (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:525-558`). A later signal during negotiation follows the same active-only no-op path.
- The normative contract requires every generic signal to be followed by a level-triggered availability read and specifically requires a binding-token signal received before assignment-result delivery to cause an immediate refresh (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:170-174`). Owner shutdown during policy negotiation must terminate with `ownerUnavailable`, without policy timeout or unrelated producer work (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:189-193`). The offline-buffer delta states the exact assignment-first/shutdown-before-result race (`openspec/changes/sdk-active-event-pump/specs/sdk-offline-buffer/spec.md:51-55`).

**Impact**

If callback assignment and its initial snapshot complete, then `NearWire` shuts down before the binding result reaches the core, the signal can be consumed while no active drain is legal. The core then enters policy negotiation and can remain alive until `policyNegotiationTimedOut` rather than terminating promptly with `ownerUnavailable`. The same failure occurs if shutdown happens after binding while no initial policy offer arrives. This changes the specified terminal result and unnecessarily retains the channel, activation waiter, registration, owner, and active dependencies for up to the policy-timeout hard limit.

**Required remediation**

Add a tokenized level-triggered owner-availability refresh that is legal during both `bindingActiveOwner` and `.negotiatingPolicy`, independently of business-Event draining. A matching pre-result signal must remain latched and be refreshed immediately after a live binding result; every later generic signal must also refresh persistent availability before interpreting queue state. Owner-unavailable must terminate through the existing single terminal authority and exact-token cleanup. Add deterministic barriers for shutdown after assignment but before result delivery, after binding with no offer, active-empty, zero-rate, and in-flight work, asserting exact `ownerUnavailable` precedence and cleanup.

### 2. P1 / High — Pre-latched run cancellation loses its required precedence to policy ownership

**Evidence**

- `registerActiveRunner` checks stored terminal state, runner state, and `policyConsumerOwner` before claiming the run cancellation gate (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:415-445`). If an attachment pull has already claimed policy ownership, line 433 returns `policyConsumerClaimed` without observing a pre-latched first-run cancellation.
- The session-admission delta defines runner precedence as same-starter second-run guard, stored terminal state, pre-latched first-run cancellation, and only then policy-consumer ownership. It explicitly requires a live pre-cancelled first run to store and return `cancelled` (`openspec/changes/sdk-active-event-pump/specs/sdk-session-admission/spec.md:3-9`).
- Existing ownership coverage exercises an ordinary pull-owned runner conflict and runner-owned pull conflict (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:239-283`), but does not combine pre-latched runner cancellation with pre-existing pull ownership.

**Impact**

A caller that starts its first pump run in an already-cancelled task after a policy pull has claimed ownership receives `policyConsumerClaimed`; the attached live core is not terminally cancelled. That violates deterministic cancellation semantics and can leave the admitted session and its permanent resources live even though the operation's required cancellation winner was already established.

**Required remediation**

After the same-starter guard and stored-terminal check, claim the first-run cancellation gate before evaluating policy-consumer ownership. A pre-latched cancellation must call the one terminal path, store `.cancelled`, and return that exact result; only a live claimed run may then resolve ownership conflicts. Add compound precedence tests for pre-cancelled runner plus pending pull, completed pull, buffered policy, and concurrent terminal state, while preserving stored-terminal-first and second-run-first behavior.

### 3. P2 / Medium — Wake assignment and its initial snapshot are not one gate-linearized transaction

**Evidence**

- `registerOutboundWorkWake` claims `SDKActiveOperationGate` only around callback assignment (`SDK/Sources/NearWire/NearWire.swift:446-463`). It releases the gate and then computes `outboundSchedule` (`SDK/Sources/NearWire/NearWire.swift:464-467`).
- Terminal cleanup can close the shared gate in that interval because `SDKActiveOperationGate.withOpenClaim` releases its lock when the assignment closure returns, while `close()` independently acquires that lock (`SDK/Sources/NearWire/Session/SDKActiveOperationGate.swift:19-34`).
- The later snapshot does not claim one enclosing transaction. It separately claims the gate only for individual expirations and can return `.available` for an empty queue after the gate has already closed (`SDK/Sources/NearWire/NearWire.swift:475-496`).
- The binding contract permits only terminal-first with no installation or install-first with assignment and snapshot completed before terminal close (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:52-70`). The offline-buffer delta likewise requires callback assignment and the initial availability/fair-candidate/deadline snapshot to be atomic (`openspec/changes/sdk-active-event-pump/specs/sdk-offline-buffer/spec.md:34-38`).

**Impact**

There is a third observable ordering: the callback is installed, terminal closes the operation gate, and only then the initial snapshot is produced. Depending on queue contents, the result can report installed plus `terminalFirst` or installed plus stale `.available`. Exact-token cleanup limits leakage, but the implementation and evidence do not establish the promised cross-actor linearization boundary, and callers cannot reason using the specification's two outcomes.

**Required remediation**

Refactor registration so assignment and a nonmutating initial owner/schedule snapshot are captured within one shared-gate claim and returned as one value. If due expirations require their own separately gated mutations, return the atomic pre-mutation snapshot first and service those expirations through a tokenized follow-up refresh; do not nest the non-recursive gate. Add a deterministic terminal barrier after assignment but before snapshot generation and prove that only terminal-first/no-install or install-first/complete-snapshot can occur.

### 4. P2 / Medium — Required active diagnostic state is decoded or removed and then discarded

**Evidence**

- A negotiated `event.drop-summary` is decoded and immediately discarded (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:890-893`). There is no core-owned counter or accumulator for its values.
- Incoming TTL maintenance likewise discards the IDs returned by `removeExpired` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1428-1448`) and records no expiry count.
- The active-pump specification requires inbound drop summaries to update saturating internal diagnostics (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:224-232,251-255`). The design also requires decoded summaries and incoming expiry removals to saturating-add their respective diagnostics (`openspec/changes/sdk-active-event-pump/design.md:144-152`). Tasks 6.1 and 6.2 retain these requirements (`openspec/changes/sdk-active-event-pump/tasks.md:30-34`).

**Impact**

Valid diagnostic input and local downlink expiry are silently forgotten. The active architecture therefore lacks part of the bounded state that the approved design and evidence claim it owns. This is not a public-API omission—the counters are intentionally internal—but it is incomplete implementation scope and prevents faithful operational diagnosis of peer drops and receiver-local expiry.

**Required remediation**

Add explicitly owned, constant-size internal diagnostic counters to the permanent core. Saturating-add every validated summary field and each removed incoming expiry without creating Events, acknowledgements, retry state, sequence changes, or unbounded history. Define terminal cleanup/snapshot ownership, and add `UInt64.max` saturation, multi-summary accumulation, multi-quantum expiry, zero-rate expiry, and terminal-race tests. If these diagnostics are intentionally deferred, narrow the active change's design, capability requirement, tasks, documentation, and evidence before claiming implementation completion.

## Verified Architecture and Boundaries

- The active pump retains the admitted permanent core, callback ingress, decoder, negotiated codec, route, secure channel, and terminal authority; it does not create a replacement transport stack.
- The returned handle/relay and separate termination observer avoid a core-to-relay ownership cycle, and exact-token cleanup is used for active callbacks and asynchronous operations.
- Dynamic policy offers wait for in-flight old-policy outbound or incoming work and are committed in receipt order; each commit prepares replacement buckets before mailbox admission and installs both directions without an intervening Event selection.
- Active implementation types remain internal or constrained to existing internal SPI composition seams. No supported SDK API, package product, CocoaPods subspec, runtime dependency, entitlement, persistence, Keychain, process lease, lifecycle observer, UI, or public state transition was added by this change.
- Shared platform-neutral code remains in `Core`, iOS-specific active ownership remains in `SDK`, and the implementation adds no third-party Core or SDK runtime dependency.

## Review Status

**Unresolved finding count: 4 — 2 High (P1), 2 Medium (P2).** Architecture/API closure is not granted. All four findings require remediation and a fresh independent review round.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check -- openspec/changes/sdk-active-event-pump/reviews/implementation-round1-architecture-api.md`: PASS with no output.
- Trailing-whitespace scan of this report: PASS with no matches.
