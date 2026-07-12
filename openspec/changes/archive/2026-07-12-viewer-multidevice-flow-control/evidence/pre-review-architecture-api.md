# Pre-Implementation Review — Architecture and API

## Review Scope

This lightweight review read `AGENTS.md` and every artifact under `openspec/changes/viewer-multidevice-flow-control`, then compared the proposed ownership and protocol seams with the current Viewer admission implementation and existing `NearWireCore`, `NearWireTransport`, `NearWireFlowControl`, and SDK session behavior. No production or test source was modified; this report is the only added file.

The review focused on preserving the existing connection core, callback, decoder, and cleanup receipt; separating the 32-owner admission bound from the 16-session product bound; reusing the existing V1 wire schema and flow-control APIs; and ensuring every manager-owned presentation/resource collection is actually finite.

Severity meanings:

- **High**: an unsafe architecture that invalidates the proposed change boundary.
- **Medium**: an actionable ownership, protocol, or finite-resource ambiguity that must be resolved before implementation.
- **Low**: a bounded maintainability or evidence defect that should be corrected before implementation but does not threaten the core design.

## Findings

### 1. Medium — The policy-acceptance rules simultaneously require conservative acceptance and exact equality

The artifacts correctly state that V1 carries no policy generation field and that only one offer may be in flight (`design.md:48-52`; `specs/viewer-multidevice-flow-control/spec.md:49-53`). They then select exact accepted-policy equality as the correlation rule and say a differing acceptance closes the session. That contradicts both the preceding componentwise rule and the normative scenario: Viewer may request 20/10 while App accepts 12/8, and 12/8 must become effective (`spec.md:51,55-59`). It also conflicts with the existing SDK, which computes each effective direction as the minimum of the Viewer offer and the App maximum and returns those potentially lower values in `WireFlowPolicyAccepted` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1161-1205`).

The existing `WireFlowPolicyOffer` and `WireFlowPolicyAccepted` payloads contain only the two rates; they contain no generation, nonce, or offer ID (`Core/Sources/NearWireTransport/WireControlPayloads.swift:341-409`). Exact equality cannot be adopted without eliminating the documented conservative negotiation behavior, while a true generation check would require the wire-schema/version change that the proposal explicitly excludes (`design.md:20-26`).

**Required resolution:** define the V1 rule consistently: at most one offer is pending, an acceptance is valid only while that offer is pending, and each accepted direction must be protocol-valid and no greater than the corresponding current offer. The accepted pair becomes effective even when lower. State explicitly that V1 correlation relies on the single in-flight transaction plus ordered stream phase because no generation exists; remove exact-equality and “differing acceptance” language. If stronger stale-response correlation is required, declare and specify the wire change rather than implying an unavailable generation. Add initial and dynamic tests for lower acceptance, escalation, acceptance with no pending offer, repeated/stale acceptance, and latest desired-policy coalescing.

### 2. Medium — The handoff artifacts do not define the synchronous, reentrant attachment boundary needed to preserve coalesced input and avoid a second protocol executor

The current core invokes `onHello` synchronously from inside its private serial queue and continuous decoder. It changes to `awaitingConsumer` before that callback, and any later frame received without a new attached state is terminal (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:205-237,309-347`). The admission manager then calls `handoffOwner.transfer` synchronously while its own terminal lock is held (`ViewerAdmission.swift:861-876,946-956`). Consequently, a successful multi-device transfer must reserve the 16-slot session entry and install the one-time active-session handler before `transfer` returns `true`; otherwise another frame coalesced after App Hello in the same receive chunk can be rejected or stranded at the ownership boundary.

The design says attachment callbacks execute on the core queue and all protocol transitions remain there (`design.md:32-34`), but it also introduces “one actor-like serial executor per session” without declaring whether this is the same core queue or a second state owner (`design.md:36`). An asynchronous hop to another executor would let decoded frames accumulate outside the current synchronous backpressure boundary; a synchronous `queue.sync` back into the core from the current callback would deadlock unless the attachment API is explicitly reentrant. The artifacts also do not specify atomic rollback if session capacity is reserved but attachment fails.

**Required resolution:** define one exact transfer transaction. While `transfer` is executing synchronously, reserve the session slot, invoke a core API that detects its own queue and installs the handler inline, and return success only after attachment is committed. On any failure, roll back the session slot and return `false` so admission retains cancellation/cleanup ownership. Declare the core's existing serial queue as the sole owner of decoder, wire phase, sequence, policy-transaction, and terminal state; per-session schedulers may own business work but must not become a second frame/protocol executor or receive an unbounded async frame stream. Define lock ordering so no manager-registry lock is held across callbacks that can re-enter the manager. Add deterministic tests for App Hello plus another coalesced frame, terminal input during transfer, attachment failure after reservation, transfer-versus-shutdown, and attempts to attach twice.

### 3. Medium — Thirty-second reconnect rows are time-limited but not count- or task-limited

Live negotiating/active ownership is bounded to 16, and preferences/nicknames are separately bounded to 256. Recently disconnected presentation is only bounded by a 30-second TTL (`design.md:40-44`; `spec.md:27-31,177-193`). Rapid churn through distinct installation IDs can create an arbitrary number of reconnect rows within that window even though only 16 sessions are live at once. The design also says expiry uses one-shot work “while such rows exist” but does not say whether there is one manager wake or one task per row. This leaves both manager memory/UI snapshot size and scheduled expiry work unbounded under churn, contrary to the change's finite-session and bounded-snapshot goals.

**Required resolution:** add an explicit maximum recent-row count with deterministic eviction (and define whether an active/replacement route is ever eligible for eviction). Require one manager-owned replaceable wake for the earliest reconnect expiry rather than one task per row, bound due-expiry work per service turn, and ensure the UI snapshot cannot exceed the live/candidate plus recent-row limits. Add churn tests that exceed the row cap within 30 seconds, validate deterministic eviction/reconnect replacement, prove one scheduled expiry owner, and show late expiry callbacks cannot remove a newer row.

## Architecture and API Checks That Passed

- The change is appropriately Viewer-scoped. It reuses repository SPI from Core and introduces no public SDK API, wire version, transport, nested manifest, podspec, entitlement, third-party runtime, database, or shell harness.
- The separate capacities are conceptually correct: admission retains its 32 connection-owner cleanup bound, while the product manager synchronously limits negotiating plus active sessions to 16. Rejected session handoff returns ownership to the existing admission cancellation path.
- Logical route identity correctly uses the validated App installation ID plus optional Bundle ID. Display name, version, alias, and nickname are not routing authority. Old-route preservation until a replacement becomes active is compatible with the existing opaque handoff.
- Queue and rate primitives already exist as repository SPI. `BoundedEventQueue`, `EventTokenBucket`, and `EventBatchScheduler` support the proposed bounded queues, zero rates, 500 ms scheduling, priority-aware overflow, keep-latest, TTL expiry, and no missed-interval replay.
- The secure channel already exposes synchronous mailbox admission with reserved count/byte capacity, capacity snapshots, and send-completion events. Extending the Viewer-internal channel/core seam can reuse those capabilities without exposing Network.framework values or changing Core public API.
- Event route, epoch, sequence, codec, lane, size, TTL, and drop-summary types already exist in Core. The SDK supplies substantial opposite-side interoperability behavior and fixtures that should be reused rather than duplicated as a new protocol.
- Control messages remain on the Control lane, while the existing `WireDropSummaryPayload` correctly remains on its protocol-defined Event lane. The current artifacts distinguish that system Event from Control traffic while allowing it to bypass business rate tokens under bounded mailbox/coalescing limits.
- Requested versus effective policy, bounded `UserDefaults` preferences, memory-only effective state and queues, content-free telemetry, no delivery acknowledgement, and UI exclusions align with current product boundaries.
- Lifecycle composition preserves foundation semantics: pause/ordinary pairing refresh do not close handed-off sessions; per-device disconnect is isolated; window/reset shutdown closes transfer first and joins every original handle through the existing cleanup receipt.
- The test plan covers the essential concurrency scale points, protocol interoperability, queue/rate bounds, device isolation, cleanup, presentation, documentation, and repository gates without claiming completion from a narrow test.

## Verdict

**Approval withheld.** The overall direction is compatible with the existing Viewer/Core/SDK architecture, but the policy rule, same-core attachment transaction, and reconnect-row ownership must be made unambiguous and finite before production or test implementation begins.

**Exact unresolved actionable finding count: 3** — 0 High, 3 Medium, 0 Low.
