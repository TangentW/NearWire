# Pre-Implementation Architecture and API Review — Round 4

## Scope Reviewed

Fresh review of the latest proposal, design, tasks, and six capability deltas against the current `NearWire` actor, admission/core terminal path, cancellation relay, one-shot waiter, active-pump retain graph, exact process lease, state/error boundary, and roadmap items 12 and 13. The review traced pre-admission failure and cleanup, admission-to-lifetime handoff, core terminal marking, Task cancellation, shutdown, active transfer, actor connected commit, async waiter delivery, weak callbacks, deinitialization, and retry. No planning or production artifact was modified.

## Previous Architecture Finding Audit

| Prior finding | Round 4 status | Evidence |
| --- | --- | --- |
| Cancellation-to-terminal lease gap | Resolved after admission; pre-admission wording remains partially open as Finding 2 | The acknowledged handoff leaves exactly one lease owner and the coordinator releases only after the sole wait observes terminal (`design.md:127-153`; `specs/sdk-process-connection-lease/spec.md:5-34`). No-lifetime branches now have an explicit attempt/cleanup owner, but their slot/release order conflicts with synchronous shutdown detachment. |
| Admission phase observer could construct a core after shutdown | Resolved | Admission rechecks its state, Task cancellation, and the synchronous authorization gate immediately after the observer and before core/channel construction (`design.md:113-117`; `specs/sdk-session-admission/spec.md:3-21`). |
| Queue, Event-record, frame, mailbox, and turn byte domains were conflated | Resolved at planning level | The fixed network bound is independent of offline queue accounting, all downstream domains are distinct, and production-encoder structural/property evidence plus exact/one-over tests are required (`design.md:35-54`; `specs/sdk-public-connect/spec.md:27-48`; `tasks.md:10-13`). |
| Post-return terminal errors had no public observation surface | Resolved | Public mapping ends at successful `connect`; later terminal causes publish only disconnected and terminal-reason history remains lifecycle scope (`design.md:161-169,181-183`; `specs/sdk-public-connect/spec.md:136-147`). |
| Connected ownership retained pairing material | Resolved | Public orchestration releases its normalized code after admission construction, admission transfers discovery ownership, and no active or terminal owner retains it (`design.md:105-111`; `specs/sdk-public-connect/spec.md:77-84`). |
| Attempt-time actor deinitialization was impossible | Resolved | The plan now states that the live instance-method Task retains the actor; attempt cleanup is driven by Task cancellation or shutdown, while post-success deinitialization is covered by the weak active binding (`design.md:56-67,155-159`; `specs/sdk-async-facade/spec.md:3-27`). |
| Hidden active handle formed a core-to-`NearWire` cycle | Resolved at planning level | `activeOwner` is removed, App rates are captured by value, all live owner operations are weak and unavailable-aware, and retain-graph/deinitialization tests are required (`specs/sdk-active-event-pump/spec.md:3-25`; `tasks.md:22,24`). |
| Terminal observation had no unique owner across admission and activation | Resolved | One lifetime supplies one relay, one termination value, and one transition gate; one coordinator starts the only wait before attachment and solely owns the lease/release action (`design.md:119-131`; `specs/sdk-session-admission/spec.md:9-31`; `specs/sdk-public-connect/spec.md:106-124`). |
| Pending shutdown had no exact public result | Resolved | Token-current shutdown overrides Task cancellation and lower-layer outcomes until the connected claim and returns `NearWireError.shutdown`; a later shutdown cannot rewrite success (`design.md:21-33,125`; `specs/sdk-public-connect/spec.md:3-25,114`). |
| Async waiter delivery could lose terminal versus connected-commit order | Resolved | The core synchronously marks the shared gate before waiter resumption or cleanup; active-transfer and connected-commit claims use the same lock; the successful connected claim is followed by owner installation, connected publication, and return in one no-suspension actor turn (`design.md:119-145`; `specs/sdk-session-admission/spec.md:9-31`; `specs/sdk-public-connect/spec.md:106-114`). Delayed waiter or callback scheduling cannot change this winner. |

## Findings

### 1. P1 / High (confidence: 9/10) — Pre-handoff Task cancellation and lifetime terminal marking still have no common chronology

**Evidence**

- The public contract says task-only cancellation before active transfer returns `connectionCancelled`, and the revised winner rule says Task cancellation versus terminal before transfer uses their order (`design.md:33,65-67,125`; `specs/sdk-public-connect/spec.md:88-90,114`).
- Until admission returns, Task cancellation is recorded in the attempt gate. The lifetime gate is created independently inside admission, and the core may synchronously mark it terminal as soon as the admitted lifetime exists. Only after the suspended public call resumes does handoff lock attempt then lifetime and copy the prior cancellation reason into the lifetime gate (`design.md:121-127`; `specs/sdk-session-admission/spec.md:9-11`; `specs/sdk-public-connect/spec.md:88-110`).
- The fixed lock order makes the handoff itself safe, but neither gate records a shared sequence or timestamp for events that occur before handoff. This ordering is therefore possible:

  ```text
  Task cancellation -> attempt gate records task
  core terminal      -> lifetime gate records terminal
  handoff             -> copies task into an already-terminal gate
  ```

  The reverse ordering is also possible. In both cases the lifetime gate only sees terminal followed by copied cancellation, so it cannot preserve both real winner orders. The current source already allows the core to terminate immediately after admitted-session resumption and before the outer caller runs (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1743-1767,1842-1929`).
- Critical-section hooks around handoff, terminal mark, and transfer can expose the race, but no normative state or task requires the cross-gate ordering information needed to resolve it (`design.md:69-84,145,171-178`; `tasks.md:17-23`).

**Impact**

A Task cancellation that happens first can surface a mapped internal terminal error instead of `connectionCancelled`, or a terminal that happens first can be overwritten if handoff gives the copied reason unconditional priority. Public result selection becomes dependent on whether the outer admission continuation resumed quickly enough, despite the plan promising one exact cancellation/terminal order.

**Required remediation**

Use one chronology authority before either event can occur. The simplest design is to create the public transition gate with the attempt, pass that same gate into admission, and have the successful `SDKSessionLifetime` adopt it; internal admission callers may create their own default gate. The gate can keep pre-admission target/authorization state and enable terminal/transfer/commit phases as ownership advances, while the lease still remains in the attempt until the acknowledged coordinator handoff. If two gates are retained, both must stamp Task cancellation and terminal mark from one shared monotonic sequence source and the handoff must resolve the original stamps, not insertion order.

Add deterministic tests that hold admission-result delivery and prove both cross-boundary winners: Task cancellation, then terminal mark, then handoff; and terminal mark, then Task cancellation, then handoff. Assert exact public error, state sequence, cancellation count, active-transfer rejection, one wait/release, shutdown override, and no stale mutation.

### 2. P2 / Medium (confidence: 10/10) — No-lifetime release order contradicts immediate public-slot detachment and the universal terminal-release rule

**Evidence**

- Shutdown must synchronously detach the exact public attempt slot while non-cancellable identity or pre-admission work may continue under non-public cleanup ownership (`specs/sdk-async-facade/spec.md:3-27`).
- The new no-lifetime rule covers stale identity after shutdown but requires exact release after the operation completes and before clearing the attempt slot or completing the pending call (`design.md:147-151`; `specs/sdk-public-connect/spec.md:149-166`; `specs/sdk-process-connection-lease/spec.md:5-24`). On that shutdown path, the public slot was already detached before operation completion and release, so the two requirements cannot both hold literally.
- The following sentence says every path releases after terminal state (`design.md:153`; `specs/sdk-public-connect/spec.md:155`). Identity failure, stale identity completion, discovery or phase failure before core construction, and other admission failures without a returned lifetime intentionally create no session transition gate, terminal wait, or coordinator. Their release trigger is operation completion, not a session terminal mark.
- Task 3.10 requires exact state and release ordering for stale identity after shutdown, so an implementation test must choose which contradictory rule to violate (`tasks.md:26`).

**Impact**

Delaying slot detachment until Keychain IPC or admission returns violates prompt final shutdown. Detaching promptly violates release-before-slot-clearing. Treating a no-lifetime operation completion as a synthetic session terminal blurs the deliberately separate cleanup regimes and can incorrectly introduce waiter/coordinator expectations.

**Required remediation**

Separate public attachment from cleanup ownership and define two exhaustive release regimes:

- An ordinary token-current no-lifetime failure completes its operation, drops the exact handle to invoke release once, then clears the public slot, publishes disconnected if discovery began, and completes `connect`.
- Task cancellation or shutdown may detach the public slot immediately. A named non-public pre-admission cleanup owner retains the attempt and lease until the operation completes, invokes release once, and performs no later actor state or slot mutation. Specify whether the pending call waits for that release invocation before returning `connectionCancelled` or `shutdown`.
- Lifetime branches transfer to the coordinator and release only after its sole wait observes the core's synchronous terminal mark.

Replace the universal “after terminal” sentence with these two regimes. Extend task 3.10 to cover ordinary failure, Task cancellation, and shutdown during identity, discovery, phase authorization, and admission, asserting public-slot timing separately from cleanup-owner and lease timing.

## Re-Audit Notes

- **Core terminal mark and waiter separation:** feasible against the current core. `finish` already has one exact first-terminal guard and one place that resumes the pending termination observer (`SDKSessionTransportCore.swift:1842-1929`); marking the shared gate before that resumption preserves one async waiter without making waiter scheduling authoritative.
- **Actor connected commit:** feasible. After an awaited activation returns, `NearWire` can claim the shared gate, install its connected owner, publish connected, and return without another suspension. Actor serialization prevents shutdown from entering during that turn; a concurrent core terminal mark is ordered by the shared lock.
- **Atomic lease handoff:** the attempt-then-lifetime lock order, acknowledgement before clearing, no callbacks while locked, and sole coordinator release are sufficient for one-owner lease transfer. Finding 1 concerns event chronology across the boundary, not duplicate or missing lease ownership.
- **Weak wake cleanup:** the revised plan remains compatible with actor-owned wake storage. Existing tokenized removal runs when the weak actor is available; after actor deinitialization, destruction of `outboundWakeRegistration` releases the callback and terminal cleanup must not hop to an absent actor (`SDK/Sources/NearWire/NearWire.swift:92,446-481`).
- **Public API and scope:** the supported surface remains one `connect(code:)` addition plus safe error cases and existing state observation. Internal gates, lifetime, coordinator, lease, Network, Security, endpoint, and certificate types remain hidden. Disconnect, reconnect, background policy, retained pairing, route replacement, and terminal-reason history remain roadmap item 13.
- **Dependency seam and limit planner:** immutable internal factories/barriers remain adequate for deterministic tests. The fixed, constant-space record formula and domain-specific downstream capacities remain feasible with the existing deterministic content and wire encoders.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Static feasibility audit against current actor shutdown and state publication, admitted-session resumption, core terminal guard and waiter resumption, cancellation relay, active-owner references, process lease deinitialization, wake storage, deterministic Event encoders, and roadmap items 12 and 13.
- `git diff --check -- openspec/changes/sdk-public-connect`: PASS before this report was added.

## Unresolved Count

**2 unresolved findings: 1 High and 1 Medium. Architecture/API planning closure is not granted.**
