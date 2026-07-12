# Pre-Implementation Review Round 3 — Architecture and API

Date: 2026-07-13

## Scope

This artifact-only review re-read `AGENTS.md`, all current artifacts under `openspec/changes/viewer-multidevice-flow-control`, and all three Round 2 reports. It compared the revised Core decoder proposal with the current `WireFrameDecoder`, `SecureByteChannel`, and `ViewerAdmissionConnectionCore` ownership paths. No production or test source was modified; this report is the only added file.

The review specifically checked observable V1 lower-acceptance attribution, exact correlation tuples versus Bundle-ID variants, removal of the undefined reconnecting state, and the scope and ownership of the proposed internal Core bounded decoder pause/resume seam.

Severity meanings:

- **High**: an unsafe architecture that invalidates the proposed change boundary.
- **Medium**: an actionable ownership, protocol, or API contradiction that must be resolved before implementation.
- **Low**: a bounded contract or evidence ambiguity that must be corrected before implementation.

## Findings

### 1. Medium — Decoder pausing does not bound the next eagerly rearmed secure-channel receive

The revised artifacts correctly move valid coalesced-frame excess from a protocol failure to a scheduling pause. They require the existing decoder to retain one bounded ordered suffix, schedule one continuation on the same connection-core executor, and process that continuation before later receive input (`design.md:111-117`; `specs/viewer-multidevice-flow-control/spec.md:187-193`). The proposed decoder operation is platform-neutral and internal, so that part is properly located in Core.

However, the retained-input bound accounts only for one configured receive chunk plus one maximum legal encoded frame (`design.md:111`; `spec.md:187`). The current `SecureByteChannel` synchronously delivers `.received(data)` and immediately rearms its next receive after the event handler returns (`Core/Sources/NearWireTransport/SecureByteChannel.swift:245-277`). The Viewer core can enqueue its continuation before returning, and its serial queue can preserve processing order, but decoder pausing alone cannot prevent the channel or driver from owning one additional receive chunk while that continuation is pending. The task plan adds only a decoder seam; it does not define secure-channel receive gating or account for that extra in-flight chunk (`tasks.md:8,27`).

Consequently, “one chunk plus one frame,” “at most one continuation,” and “later input cannot overtake” do not yet form a complete retained-memory ownership contract. Queue FIFO can preserve protocol order, but it does not make the additional channel-owned bytes disappear. A hard-limit configuration can satisfy the stated decoder bound while the complete connection retains more bytes than were validated.

**Required resolution:** choose and specify one complete same-core receive contract. Either add an internal bounded pause/resume gate to `SecureByteChannel` so it does not rearm receive until the decoder continuation releases the pause, or retain eager rearming and validate/account for the decoder suffix plus the one additional channel/driver chunk and its single blocked callback ingress. In both cases, define exact cancellation and generation behavior, prove that at most one additional owner exists, and add a test with an immediately completing next receive while a suffix continuation is pending. Update proposal/design/spec/tasks so the Core surface actually matches the selected ownership model; do not imply that a decoder-only API controls channel rearming.

### 2. Low — Split/coalesced token equivalence is stated without an arrival-time condition

The decoder continuation intentionally charges all frames retained from one callback at that callback's original monotonic receipt sample (`design.md:115`; `spec.md:191`). The artifacts then require split and coalesced delivery of the same bytes to produce the same token and terminal outcome (`design.md:149`; `spec.md:191,218-233`; `tasks.md:27-28`).

That equivalence is only possible when the compared deliveries use the same effective receipt-time samples. Separate callbacks can occur across a token-refill boundary, while one coalesced callback necessarily has one receipt sample. For example, a split system burst spanning enough time may legally refill its 64-per-second bucket, while the same messages coalesced at the earlier sample may exceed the burst available at that instant. The difference then comes from elapsed time, not TCP segmentation, and requiring identical token outcomes would contradict the time-based rate contract.

**Required resolution:** qualify the normative equivalence. Identical bytes presented with the same injected receipt-time schedule, differing only in callback partitioning, must have identical protocol, sequence, queue, token, and terminal outcomes. When split callbacks have genuinely later monotonic receipt samples, only the documented token refill may change acceptance. Require tests for both same-sample partition equivalence and a controlled refill-boundary case; keep continuation turns for one callback pinned to its original sample.

## Round 2 Remediation Verification

- **Observable V1 attribution:** resolved. With one offer pending, every protocol-valid componentwise-lower pair is attributed to that transaction even when it equals an earlier acceptance; only an acceptance with no pending offer is observably repeated. The design, normative scenarios, risk statement, and task tests now agree (`design.md:64-81,146`; `spec.md:73-109`; `tasks.md:10,26`).
- **Exact tuple and Bundle variants:** resolved. The correlation key remains installation ID plus optional Bundle ID. An exact tuple duplicate is rejected in either admission mode, while a same-installation different/missing Bundle ID is a separate unauthenticated row that cannot disturb or inherit the original nickname, selection, session, or downlink queue (`spec.md:41-57`; `tasks.md:9,26`).
- **Reconnecting state:** resolved. Returning connections enter the ordinary negotiating state, and the workspace lists only negotiating, active, disconnecting, and recently disconnected rows. No separate reconnecting state or presentation oracle remains (`design.md:50-58,129-133`; `spec.md:261-277`).
- **Core/Viewer scope:** the new decoder capability is shared, platform-neutral, and internal Core SPI; Viewer retains policy, scheduling, UI, persistence, and lifecycle. It changes neither supported SDK API nor wire behavior and has explicit Core plus Viewer coverage. Finding 1 concerns the adjacent secure-channel ownership needed to make its bound true, not a request to move Viewer policy into Core.
- **Earlier ownership bounds:** synchronous reentrant same-core attachment, 16 provisional/negotiating/active/disconnecting owners, 64 recent rows with one manager wake, exact connection-bound downlink work, and latest-only UI snapshots remain coherent.

## Verdict

**Approval withheld.** All Round 2 product/protocol/state findings are resolved, and the internal Core decoder seam is appropriately scoped, but the complete receive-retention ownership and time-qualified equivalence contract must be corrected before implementation.

**Exact unresolved actionable finding count: 2 — 0 High, 1 Medium, 1 Low.**
