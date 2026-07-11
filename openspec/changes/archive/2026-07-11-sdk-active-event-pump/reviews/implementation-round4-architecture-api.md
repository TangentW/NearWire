# Post-Implementation Architecture and API Review — Round 4

## Findings

### 1. P2 / Medium (confidence: 10/10) — Wake assignment and its initial snapshot still permit a third terminal ordering

**Evidence**

- `registerOutboundWorkWake` claims the shared gate only around callback assignment, releases that claim, and then calls `outboundSchedule` to construct the returned snapshot (`SDK/Sources/NearWire/NearWire.swift:446-470`).
- `outboundSchedule` claims the gate only when committing each due expiration (`SDK/Sources/NearWire/NearWire.swift:478-496`). If no expiration is due, terminal can close the gate after assignment and the method still returns `.available`; if an expiration is due, the first losing expiry claim returns `.terminalFirst` while `installed` remains true.
- The new per-expiration test intentionally demonstrates the latter result: assignment and the first expiry claim win, terminal closes before the second expiry claim, and registration returns `installed == true` with `.terminalFirst` (`SDK/Tests/NearWireTests/NearWireBufferTests.swift:114-170`). This correctly proves separate expiry claims but also proves that assignment plus initial snapshot is not one gate-linearized outcome.
- The normative binding contract allows only terminal-first with no installation or install-first with assignment and the complete initial snapshot preceding terminal close (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:52-70`; `openspec/changes/sdk-active-event-pump/specs/sdk-offline-buffer/spec.md:34-43`). The current ownership audit instead documents the non-atomic observation after assignment (`openspec/changes/sdk-active-event-pump/evidence/ownership-resource-audit.md:5-17`).

**Impact**

Exact-token cleanup prevents a permanent callback leak in the permanent core, but the internal registration API still exposes an outcome forbidden by its specification: an installed wake with no valid atomic initial snapshot. Callers and future orchestration cannot treat `installed` as proof that the associated owner/candidate/deadline observation committed before terminal, and the current test and evidence normalize rather than close that contract gap.

**Required remediation**

Add a nonmutating initial-schedule observation that can run inside the same gate claim as token assignment. It should report owner availability and the exact candidate/deadline or due-work state without expiring Events. After the atomic registration result is delivered, service due work through the ordinary refresh path so every expiration retains its own gate claim. Update binding to latch follow-up work from that snapshot, and replace the current registration race assertion with tests proving only terminal-first/no-install or install-first/complete-snapshot while preserving a separate terminal-between-expirations test.

### 2. P2 / Medium (confidence: 10/10) — `SDKActiveLiveOperations` binds the right objects but does not expose the required operation-specific barrier surface

**Evidence**

- The new immutable value correctly captures the exact `NearWire`, `SecureByteChannel`, session clock, and operation gate, and the permanent core stores it before wake installation (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:110-188`; `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:521-555`). Clock, wake, schedule, drain, core mailbox checks/admission, and publication now route through its typed closures.
- Its hook type exposes only clock, wake registration/removal, schedule, drain, core mailbox capacity/admission, and publication entry (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:77-107`). It has no operation-specific seam for expiry, route-drop, or candidate gate claims, mailbox completion, observer cancellation, or terminal close.
- `beforeMailboxAdmission` runs only through the Control-oriented `admitSend` closure (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:180-183`). App Event mailbox admission and the progress snapshot that forms its blocked result happen inside `NearWire.drainActiveWire` without invoking that hook (`SDK/Sources/NearWire/NearWire.swift:653-701`). Candidate, expiry, and route-drop tests can therefore target only ordinal calls to the one generic gate hook (`SDK/Sources/NearWire/Session/SDKActiveOperationGate.swift:3-34`), while channel completion, observer cancellation, and terminal close remain outside the live-operation hook surface (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:714-722,761-763,1839-1845`).
- The approved design and normative specification require barrier-capable dependencies specifically at candidate admission, mailbox completion, terminal close, observer cancellation, and each candidate/expiry/route claim, not merely one global gate counter (`openspec/changes/sdk-active-event-pump/design.md:156-160`; `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:297-305`). Current tests use the new live hooks only for schedule and drain entry (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:931-990`).

**Impact**

The immutable binding fixes owner/channel substitution risk, but the intended test architecture remains coupled to incidental claim order and concrete fixture callbacks. Adding a new gated mutation or reordering one existing claim can silently retarget an ordinal barrier, and the Event-admission, completion, cancellation, and terminal boundaries cannot be paused through the operation value that evidence now claims owns them.

**Required remediation**

Extend the fixed live-operation boundary with typed operation-specific barriers for Event mailbox admission and progress completion, expiry/route/candidate claims, observer cancellation, and terminal close. Pass the relevant hooks into the concrete NearWire/channel/gate operations so the live implementation still performs the same validation and shared-gate claim. Replace claim-number tests with the corresponding named seam. If the generic gate plus fixture-driver model is intentionally preferred, narrow the design, capability requirement, task, documentation, and evidence in a separately reviewed OpenSpec change.

## Unresolved Count

**2 unresolved findings: 2 Medium.** Architecture/API closure is not granted.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round4-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round4-swiftpm-cache swift test --filter 'SDKSessionAdmissionTests|NearWireBufferTests'`: PASS — 96 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check` before this report: PASS with no output.
