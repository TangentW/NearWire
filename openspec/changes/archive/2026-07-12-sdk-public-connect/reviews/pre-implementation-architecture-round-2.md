# Pre-Implementation Architecture and API Review — Round 2

## Scope Reviewed

Fresh review of the revised proposal, design, tasks, and five capability deltas against the current facade, permanent session core, active-pump handle and live-operation ownership, one-shot terminal observer, process lease, admission handoff, public state/error types, wire limits, and roadmap items 12 and 13. Round 1 findings were treated as hypotheses and rechecked from the revised artifacts and current implementation.

## Round 1 Resolution Audit

- **Round 1 finding 1, cancellation-to-terminal lease gap:** the revised contract now correctly separates public detachment from delayed exact lease release and preserves fail-closed runtime limitations. However, the terminal capability that makes the cleanup owner implementable is still not single-owned; this remains open as Round 2 finding 2.
- **Round 1 finding 2, admission phase suspension:** resolved. The revised admission delta requires cancellation checks before and after observer suspension and prohibits core/channel construction after cancellation (`specs/sdk-session-admission/spec.md:5-24`).
- **Round 1 finding 3, byte-domain composition:** resolved at planning level. The connection-limit planner names each byte domain, runs before lease claim, uses checked worst-case V1 expansion, rejects unsupported configuration with `invalidConfiguration`, and requires real exact/one-over traversal tests (`design.md:59-72`; `specs/sdk-public-connect/spec.md:25-39`; `tasks.md:10-11`).
- **Round 1 finding 4, undeliverable post-return errors:** resolved. Connect-completion errors and post-return terminal state are now separate, with terminal-reason observation deferred to roadmap item 13 (`design.md:187-211`; `specs/sdk-public-connect/spec.md:133-147`).
- **Round 1 finding 5, pairing-code retention:** resolved. Public ownership ends after admission construction, and no active or cleanup owner retains the code (`design.md:165-167`; `specs/sdk-public-connect/spec.md:82-89`).
- **Round 1 finding 6, attempt-time actor deinitialization:** the revised text correctly says a live instance-method Task retains the actor and moves attempt cleanup to task cancellation or shutdown (`design.md:104-106`; `specs/sdk-async-facade/spec.md:7,24-27`). The promised active-owner deinitialization is still impossible under the current active-pump retain graph; this remains open as Round 2 finding 1.

## Findings

### 1. P1 / High (confidence: 10/10) — The hidden active handle creates a strong cycle that prevents the promised connected-owner deinitialization

**Evidence**

- The revised plan requires dropping the final externally held `NearWire` after `connect` returns to run actor deinitialization, transfer the active owner to cleanup, cancel the session, and retain the lease until terminal (`openspec/changes/sdk-public-connect/design.md:104-106,120-131,175-185`; `specs/sdk-async-facade/spec.md:7,19-27`; `tasks.md:21-23`). The weak public terminal callback is presented as the mechanism that permits this.
- The current active pump has two independent strong paths from the permanent core back to the facade. `SDKSessionTransportCore` stores `activeOwner: NearWire?` and assigns the exact owner during activation (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:202-205,521-529`). `SDKActiveLiveOperations`, also retained by that core, captures `owner` strongly in its clock, wake, schedule, drain, and publication closures (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:137-224`). Both are released only during core terminal cleanup (`SDKSessionTransportCore.swift:1865-1873`).
- The public composition adds the reverse strong edge: `NearWire -> connected owner -> SDKActiveEventPumpHandle -> cancellation relay -> permanent core`. The resulting cycle is independent of whether the separate terminal Task captures `NearWire` weakly.
- Today the internal active-pump design relies on an external handle deinitializing to request cancellation (`SDKActiveEventPump.swift:285-300`). Once that handle is hidden inside the actor that the core strongly retains, releasing the App's final reference cannot reach either the actor deinitializer or handle deinitializer. With no public disconnect in item 12, the lease and session can remain live until a remote/internal terminal cause happens.

**Impact**

The active-owner deinitialization requirement and its retention test cannot pass against the current composition. An App that simply releases its connected `NearWire` can leak the facade, active session, terminal ownership, and process lease for an unbounded period.

**Required remediation**

Add `sdk-active-event-pump` as a modified capability in this change and explicitly break every core-to-facade strong edge after binding. Capture the immutable configuration and exact instance clock independently, make owner actor operations weak/unavailable-aware, and remove or weaken `activeOwner` so owner disappearance yields the existing `ownerUnavailable`/terminal path without retaining the owner. Preserve exact wake removal and gate ordering when the weak owner is absent. Add a retain-graph audit and deterministic test proving that, after successful public connect, dropping the last App reference deinitializes `NearWire`, deinitializes/cancels the hidden handle, reaches core terminal state, and releases the lease through cleanup. A weak terminal callback alone is insufficient evidence.

### 2. P1 / High (confidence: 10/10) — Terminal observation is not assigned one owner across admitted, active, connected, and cleanup states

**Evidence**

- The design says an admitted attachment that loses ownership is cancelled and held until its permanent core reports terminal; an active handle that loses ownership moves “with its one-shot termination observer and lease” into a cleanup owner; a connected owner retains the handle, observer, and lease while also starting a terminal-observation Task (`openspec/changes/sdk-public-connect/design.md:120-129,175-183`; `specs/sdk-public-connect/spec.md:149-163`).
- The current admitted and attachment handles expose cancellation but no owned terminal observation (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:35-104`). Only `SDKActiveEventPumpHandle` creates a termination value (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:285-292`). That value is strictly one-shot: a second `wait()` fails with `terminationWaitAlreadyStarted` (`SDKActiveEventPump.swift:311-339`), and the permanent core permits only one pending termination observation (`SDKSessionTransportCore.swift:685-713`).
- The revised plan does not say when `SDKPublicConnectionCleanupOwner` is created, which object exclusively owns the one-shot wait, how a lost admitted attachment obtains terminal evidence, or what shutdown transfers after the connected terminal Task has already started waiting. Literal “transfer the observer to cleanup” after that Task began either creates a second wait or leaves cleanup dependent on a Task whose lifetime/lease ownership is not defined.
- Task 3.5 asks for connected and cleanup owners but does not require an admitted-to-active terminal-capability handoff or assert exactly one terminal waiter (`openspec/changes/sdk-public-connect/tasks.md:21-24`).

**Impact**

One implementation can release the lease after cancellation request because the admitted owner has no waiter; another can hold it forever; another can start two waits and receive an observer-local error instead of terminal state. Shutdown and deinitialization cannot be proven to retain the lease through exactly one terminal completion.

**Required remediation**

Specify one terminal-cleanup capability and its transfer table before implementation. A practical design is: create an unused permanent-core termination value for admitted/attachment loss; if activation loses, cancellation plus that value are transferred to cleanup and exactly one wait starts; if activation succeeds, discard the unused fallback and create one cleanup coordinator from the active handle's termination value and lease before actor commit. That coordinator, not both the actor owner and a second Task, must be the sole owner of the one-shot wait and lease. The connected owner should retain the active handle plus the already-running coordinator; shutdown/deinit only request handle cancellation and drop the actor edge while that same coordinator continues waiting. Add modified session-admission/active-pump capability text if a new terminal-capability factory is required, and tests for loss before attachment, after attachment, during activation, after handle return, after wait registration, terminal-first, shutdown-first, and attempted duplicate wait.

### 3. P2 / Medium (confidence: 9/10) — Shutdown cancellation has a reason bit but no specified result for the pending public connect call

**Evidence**

- The attempt state explicitly records cancellation reason `task` or `shutdown`, and shutdown remains authoritative through actor owner installation (`openspec/changes/sdk-public-connect/design.md:74-106`; `specs/sdk-public-connect/spec.md:91-110`).
- The public contract defines `connectionCancelled` for caller task cancellation and the existing `NearWireError.shutdown` for a new call made after shutdown (`design.md:45-57,187-209`; `specs/sdk-async-facade/spec.md:3-7`).
- No requirement says what the already-pending `connect(code:)` throws when `shutdown()` wins during identity work, phase delivery, admission, attachment, or activation. It also does not define precedence when task cancellation and shutdown both latch before the pending call completes. The generic “both-winner” tasks assert resource cleanup but not the public error (`tasks.md:17-24`).

**Impact**

Equivalent shutdown races can surface either `connectionCancelled`, `shutdown`, or a stale lower-layer error depending on implementation timing. The instance reaches final `shutdown`, but the public call has no stable matching result, weakening the otherwise explicit error/state boundary.

**Required remediation**

Define the pending-call result in the normative winner protocol. Recommended: task-only cancellation before transfer maps to `connectionCancelled`; token-current shutdown before actor connected commit overrides task/lower-layer cancellation and makes the pending call return the existing `shutdown` error; after connected commit, `connect` returns success and later shutdown is lifecycle state only. Add table-driven barriers for task-first-then-shutdown, shutdown-first-then-task, shutdown versus identity/admission/activation result, and transfer-versus-shutdown, asserting exact public error, final state, no connected publication, and delayed lease ownership.

## Architecture and Scope Notes

- The revised Keychain worker, fixed metadata construction, limit planner, public error boundary, pairing lifetime, and immutable orchestration dependency seam are coherent with roadmap item 12 and do not add reconnect, background, UI, or terminal-history policy from item 13.
- The limit planner is feasible only if its proof uses the real queue accounting encoder and real V1 record/frame encoders as tasks 2.3 and 2.4 now require. No estimate-only evidence should satisfy the gate.
- Cleanup and active-owner work remains sequentially coupled to the current session module; there is no safe independent implementation lane until the retain graph and one-shot terminal-capability ownership above are resolved.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- `git diff --check -- openspec/changes/sdk-public-connect`: PASS with no output before this report was added.
- Current-source retain graph and one-shot observer audit: confirmed the strong core-to-owner paths, handle-to-core path, one-shot local guard, and single pending core observer described above.

## Unresolved Count

**3 unresolved findings: 2 High and 1 Medium. Architecture/API planning closure is not granted.**
