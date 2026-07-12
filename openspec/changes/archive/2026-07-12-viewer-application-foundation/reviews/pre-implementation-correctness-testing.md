# Pre-Implementation Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently reviewed `AGENTS.md`, the complete active `viewer-application-foundation` proposal, design, capability specifications, task plan, relevant existing secure-listener and wire-admission boundaries, current repository validation conventions, and the explicit later-change deferrals. This is a lightweight artifact review; no production, test, specification, task, evidence, or documentation file was modified.

## Findings

### 1. P1 / High — The admission bound starts too late and does not bound pre-hello work

**Confidence: 10/10**

The change is described as bounded pre-session admission, but the normative 32-attempt and 15-second limits apply only after a valid hello enters confirmation retention (`specs/viewer-application-foundation/spec.md:82-104`). The decoder requirement mentions rejecting “timeout” without defining when that deadline begins or how long it is (`spec.md:84`), and default-automatic admission has no pending-list phase at all. The design has the same split: decision 6 limits only confirmation retention (`design.md:61-65`), while the risk mitigation more broadly says to enforce 32 attempts and one 15-second deadline per attempt (`design.md:82-85`). Task 4.3 cannot resolve which statement is authoritative (`tasks.md:22`).

As written, many TLS connections can be claimed concurrently and then stall before sending a complete App `WireHello`. They consume secure channels, decoder state, Tasks, and callbacks without occupying one of the 32 confirmation slots; this is possible in both automatic and confirmation modes. Per-channel frame and byte limits do not bound the number or lifetime of those attempts. Window shutdown eventually cancels them, but ordinary listening has no total resource bound.

**Required resolution:** define one admission capacity that is reserved before starting per-connection hello work and covers every claimed, pre-hello, and confirmation-pending attempt in both policies. Define one monotonic pre-session deadline from claim to handoff/cancel; it may be 15 seconds if that is the intended single budget, or a separately named bounded hello deadline followed by the existing approval deadline. State whether transition from pre-hello to pending retains the same capacity slot. Add deterministic clock/gate tests for a silent peer in automatic and confirmation modes, the exact 32/33 boundary before any hello, partial-frame timeout, capacity release on every terminal path, and shutdown while all slots are occupied.

### 2. P2 / Medium — Admission controls lack a total transition table for in-flight and pending attempts

**Confidence: 10/10**

The task plan explicitly requires tests for policy toggle, pause, stale callbacks, listener replacement, and shutdown (`tasks.md:21-27`), but the artifacts do not assign unique outcomes for several normal races:

- Disabling `Require approval for new devices` while rows are already pending may auto-handoff them, leave them awaiting their original decision, or cancel them; no choice is normative.
- Pause says to reject “new” attempts and preserve handed-off connections (`spec.md:86,106-110`), while the design lists pause as a terminal gate for an attempt (`design.md:65`). It is unclear whether pause cancels connections already decoding hello and rows already pending approval or only connections accepted after the pause flag changes.
- Ordinary refresh preserves handed-off connections and starts a replacement listener (`spec.md:61-65`; `design.md:51`), but the outcome for old-listener pre-hello and pending attempts is implicit. The design's terminal list suggests replacement cancels them, while the spec states only what happens to handed-off connections. Replacement startup failure also does not explicitly say whether the old registered listener remains usable.

These choices affect user-visible rows and exact handoff-versus-cancel ownership. An implementation and its tests could select different plausible behaviors while both claiming conformance. The one-terminal-gate requirement prevents double completion only after the desired transition has been defined.

**Required resolution:** add a compact transition table over at least `claimed/preHello`, `pendingApproval`, and `handedOff` for approval-policy changes, Pause/Resume, replacement commit/failure, shutdown, timeout, Accept, and Reject. A simple proportionate policy would snapshot approval when a valid hello reaches the decision point, let existing pending rows keep that decision, have Pause/replacement/shutdown cancel every not-yet-handed-off attempt, and keep the old listener on replacement failure; another coherent policy is acceptable if specified. Tests should use the same injected terminal gate and clock to order both winners without wall-clock sleeps or live Bonjour.

## Proportionate Coverage Assessment

Apart from the two admission gaps, the plan is concrete and testable without excessive validation machinery:

- DER length/signature/certificate fixtures plus Security parsing, Keychain transition tests, random-source injection, and exact pairing-code validation are appropriate for the narrow identity implementation.
- Listener generation tokens, explicit registration events, injected callbacks, and terminal gates are sufficient for readiness/rename/cancel races; a live Bonjour integration test is useful evidence but need not replace deterministic unit tests.
- Presentation-model and SwiftUI composition smoke tests avoid brittle pixel assertions while covering disabled states, safe text, accessibility labels, and recovery actions.
- Building/testing the committed Viewer scheme, then running existing Core/SDK, structure, boundary, package, podspec, English, diff, workspace, and strict OpenSpec gates is a proportionate completion gate. No new parallel source-text or exact UI-tree validator is needed.
- Requirement-to-evidence audit and three independent implementation reviews are adequate final controls once every task maps to real evidence.

## Deferral Assessment

The later-change boundary is coherent. This change owns identity, publication, hello decoding, approval, and an opaque one-shot handoff; the placeholder consumer closes that handoff. Hello acknowledgement, initial flow policy, active multi-device ownership, Event transfer, storage, search, explorer UI, controls, and performance charts remain explicitly deferred to `viewer-multidevice-flow-control` and later Viewer changes. Ordinary refresh preserving already handed-off ownership is compatible with that future consumer boundary. Demo, menu-bar, daemon, additional windows, signing, and notarization are also consistently excluded.

## Validation

- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.

## Verdict

**Pre-implementation correctness/testing approval withheld. Exact unresolved actionable finding count: 2 — one High and one Medium.**
