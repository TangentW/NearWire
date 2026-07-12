# Pre-Implementation Review Round 2 — Architecture and API

Date: 2026-07-13

## Scope

This artifact-only review re-read `AGENTS.md`, every current artifact under `openspec/changes/viewer-multidevice-flow-control`, and the first-round architecture/API report after remediation. It checked the amended design against the existing same-core admission/handoff architecture and the established V1 policy payloads. No production or test source was modified; this report is the only added file.

The review specifically re-evaluated conservative V1 policy acceptance, synchronous reentrant same-core attachment, duplicate live-claim rejection, bounded recent-disconnect rows, and the Core/Viewer boundary.

Severity meanings:

- **High**: an unsafe architecture that invalidates the proposed change boundary.
- **Medium**: an actionable ownership, protocol, or API contradiction that must be resolved before implementation.
- **Low**: a bounded maintainability or evidence defect that should be corrected before implementation.

## Findings

### 1. Medium — V1 cannot identify a stale acceptance while a later offer is pending

The remediation correctly removed exact-equality acceptance and now permits a componentwise conservative result: each accepted value is valid when it is protocol-valid and no greater than the corresponding pending offer, and a 20/10 offer may therefore become effective as 12/8 (`design.md:64-68`; `specs/viewer-multidevice-flow-control/spec.md:67-75`). It also correctly states that V1 has no policy generation or nonce and relies on one pending offer plus ordered stream phase.

However, the artifacts still require a repeated or stale acceptance to close the session (`design.md:66,80`; `spec.md:69,84-97`; `tasks.md:26`). That is only observable when no offer is pending or when the payload violates the current offer. Once a later offer is pending, a delayed duplicate of a prior lower acceptance can be indistinguishable from a valid conservative acceptance of the current offer. For example, after accepting 12/8 for an earlier 20/10 offer, a duplicate 12/8 received during a later 15/9 offer satisfies every available V1 field and phase check. Ordered byte delivery does not supply a transaction identity.

The current requirements therefore demand detection that the unchanged V1 API cannot implement, and two conforming implementations could either close or commit the same wire input.

**Required resolution:** define the observable V1 rule precisely. An acceptance received with no pending offer is repeated/stale and closes. While an offer is pending, any protocol-valid pair no greater than that offer is attributed to the current transaction and becomes effective, even if it could semantically be an old duplicate; a later additional acceptance then closes if no next offer is pending. Remove the broader detectable-stale claim and amend the tests to cover both distinguishable repetition and the indistinguishable lower-pair case. If semantic stale-response detection is required, specify a generation/nonce wire change instead of claiming V1 can provide it.

### 2. Medium — The duplicate-claim scenario conflicts with the declared correlation-key boundary

The design and normative requirement define the logical correlation key as the App installation ID combined with the optional Bundle ID, explicitly making a missing Bundle ID a valid distinct key (`design.md:42`; `spec.md:41`). Live-claim rejection is then defined for a second claim of the same correlation key (`design.md:44,50-54`; `spec.md:43`).

The normative scenario instead requires rejection when the second peer has the same installation ID and a Bundle ID that is the same, missing, or spoofed (`spec.md:47-51`), and task 5.1 carries the same ambiguity into the test plan. If the original route has a nonmissing Bundle ID, changing or omitting it produces a different key under the declared algorithm. Such a connection cannot simultaneously be a same-key duplicate that must be rejected. The artifacts therefore do not determine whether installation ID alone is a global live-claim key or whether the tuple is authoritative.

This does not reintroduce healthy-session replacement: a different tuple can be admitted as a separate unauthenticated route without inheriting the original nickname, selection, downlink queue, or session authority. The ambiguity is nevertheless architectural because it changes admission capacity, registry uniqueness, and expected tests.

**Required resolution:** choose and state one rule. The recommended V1 rule is to keep the declared tuple correlation key: reject only an exact live tuple claim under both admission modes; treat the same installation ID with a different or missing Bundle ID as a distinct unauthenticated route; and prove that it neither disturbs nor inherits presentation/downlink ownership from the original. Alternatively, if installation ID alone must exclude every live variant, define a separate live-claim key and its relationship to tuple-based recent rows, preferences, and UI selection. Update the scenario and task 5.1 with exact expected outcomes for each same/missing/spoofed Bundle-ID case.

## First-Round Remediation Verification

- **Conservative policy acceptance:** the unsafe exact-equality rule is removed. Lower accepted values are normative, requested/effective values remain separate, one offer is pending, and monotonic deadline winners are explicit. Finding 1 above is limited to the remaining impossible stale-detection claim.
- **Same-core handoff:** resolved. Transfer reserves a provisional slot, releases the registry lock, attaches inline when already on the core queue, installs the handler before returning success, preserves coalesced frames, keeps the core queue as the sole protocol executor, and rolls back to admission cleanup ownership on failure (`design.md:32-38`; `spec.md:5-37`; `tasks.md:8,26`).
- **Recent rows:** resolved. The artifacts now impose a global 64-row cap, deterministic oldest-first eviction, one manager-owned replaceable expiry wake, a 64-row service quantum, generation checks, exact boundary behavior, a 16-plus-64 snapshot bound, and zero shutdown ownership (`design.md:46-60`; `spec.md:45-63,203`; `tasks.md:9,26-28`).
- **Duplicate live replacement safety:** the healthy connection is no longer replaced from unauthenticated hints, and downlink ownership remains bound to the exact connection and epoch. Finding 2 concerns only which input values constitute a duplicate key.
- **Core/Viewer boundary:** resolved. The change remains Viewer-scoped, reuses existing Core SPI and wire types, keeps Network.framework and decoder ownership inside the original core, and adds no public SDK API, wire version, nested manifest, entitlement, database, or third-party runtime dependency.

## Verdict

**Approval withheld.** The three first-round architecture/API findings have been materially remediated, but two residual protocol/identity contradictions must be made implementable and testable before production or test source work begins.

**Exact unresolved actionable finding count: 2 — 0 High, 2 Medium, 0 Low.**
