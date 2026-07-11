# Post-Implementation Correctness and Testing Review — Round 5

## Scope

Reviewed the complete current `sdk-active-event-pump` diff from scratch after the atomic wake-snapshot and named-operation-hook changes. The review covered proposal, design, capability specifications, task plan, production source, tests, documentation, evidence, and all prior implementation review reports. It retraced owner binding, queue preview semantics, terminal and lost-wake ordering, initial and dynamic policy activation, per-mutation gate claims, mailbox backpressure, stale results, task bounds, retained accounting, and the complete current test inventory. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Round 4 Remediation Verification

- Wake registration now performs exact token assignment and `previewActiveSchedule` inside one shared-gate claim. Terminal-first therefore installs nothing, while install-first completes one nonmutating snapshot before terminal close can proceed. NearWire actor serialization ensures work before assignment appears in that snapshot and work after assignment reaches the installed callback.
- `previewActiveSchedule` plans on a queue value copy. The due-work path returns no expired IDs, candidate, or future deadline and leaves queue count and statistics unchanged; the future-work path returns the exact fair candidate and origin deadline without consuming stored fairness. Actual due expiration remains in `outboundSchedule`, where every item uses its own named expiration hook and gate claim.
- The due-initial-snapshot path is complete. Binding latches `observation.dueWorkRemains` into `outboundWorkRequested` before ingress resumes. A buffered initial offer is consequently deferred behind one bounded owner refresh; terminal, owner-unavailable, and clock failure retain precedence. A live refresh then activates the oldest deferred policy before any relatched successor, preserves remaining due-work state, and starts the active drain. The queue-level due preview/expiration test and the permanent-core captured-live-policy and signal-storm tests exercise the exact two typed boundaries of this composition.
- Named hooks now target expiration, route-drop, candidate, Event-mailbox admission and progress observation, mailbox-completion delivery, observer cancellation, and terminal close. The hook tests use the production owner, channel, operation gate, and validation paths; they do not substitute state changes or bypass terminal authorization.
- Rechecked prior correctness closure for zero/fractional/one/burst allowance, the 81-case limiter matrix, terminal after a committed uplink prefix, dynamic-policy clock reversal, completion-before-blocked-result, controlled no-poll behavior, downlink publication winners, policy FIFO order/overflow, combined FIFO/in-flight accounting, subscriber isolation, and bounded complete-frame decoding. No regression was found.

## Findings

None.

## Review Status

**Unresolved finding count: 0. Correctness/testing closure is granted for Round 5.**

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-r5-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-r5-swiftpm-cache swift test --filter 'SDKSessionAdmissionTests|NearWireBufferTests|BoundedEventQueueTests'`: PASS — 134 tests, 0 failures (`71 + 26 + 37`).
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-r5-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-r5-swiftpm-cache swift test`: PASS — 361 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
