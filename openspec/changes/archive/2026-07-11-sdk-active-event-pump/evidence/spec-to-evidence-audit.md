# Spec-to-Evidence Audit

## Audit Result

The complete `sdk-active-event-pump` change was audited against every added or modified capability requirement, every scenario group, every task, the supported API boundary, and the final current-diff validation results. No missing, contradictory, stale, or indirect requirement evidence remains.

## Capability Coverage

| Capability delta | Requirements audited | Evidence conclusion |
| --- | ---: | --- |
| `event-rate-control` | 1 | Captured whole-token allowance and prevalidated commit are covered by bucket tests plus permanent-core zero/fractional/one/burst tests. |
| `bounded-event-queue` | 2 | Nonmutating initial preview, bounded scheduling, separate expiration authorization, active offering, fairness, bytes, and terminal outcomes have direct Core and SDK tests. |
| `secure-byte-channel` | 1 | Count/byte reservations, capacity progress, FIFO, completion release, concurrency, predicate races, and terminal cleanup have direct mailbox tests. |
| `sdk-offline-buffer` | 3 | Active wire drain, coalesced owner wake behavior, atomic assignment/snapshot, named mutation seams, and publication terminal ordering have direct actor/gate tests. |
| `sdk-session-admission` | 3 | Single-run ownership, parked ingress, cancellation precedence, permanent core ownership, and closed diagnostics have direct admission tests. |
| `sdk-active-event-pump` | 9 | Explicit start/lifetime ownership, policy, bounded bidirectional pumping, scheduling, limits, cancellation, security, and residual public-connect scope have direct focused, integration, and boundary evidence. |
| `sdk-public-boundary` | 1 | Consumer fixtures and static checks prove ordinary supported queue use starts no connection or lifecycle feature. |

The exact requirement-to-test mapping, including named scenario groups and production TLS composition, is recorded in `requirement-to-evidence.md`. The audit found all 20 requirement headings represented there with direct executable or boundary evidence.

## Cross-Cutting Invariants

- **Atomic owner binding:** wake assignment and the nonmutating initial scheduling snapshot share one gate claim; due work is later serviced under separate per-expiration claims.
- **Fixed operation identity:** one immutable internal value binds the exact owner, admitted channel, session clock, and shared gate before active mutation.
- **Named race boundaries:** expiration, route drop, candidate, Event-mailbox admission/progress, mailbox completion, publication, observer cancellation, and terminal close have operation-specific seams that do not replace production validation or ownership.
- **Bounded retention and work:** secure sends, callback ingress, partial decode, completed frames, uplink queue work, blocked-candidate state, downlink FIFO/in-flight accounting, deadline index, deferred policies, tasks, one-shot wakes, and subscriber buffers each have explicit independent bounds.
- **Terminal linearization:** queue/mailbox commits and incoming publication have only operation-first or terminal-first outcomes; late tokens cannot install bucket, sequence, policy, or retained state.
- **Security and delivery semantics:** all active bytes remain on the admitted mandatory TLS 1.3 channel; no plaintext path, authentication overclaim, persistence, replay, acknowledgement, or exactly-once claim was introduced.
- **Distribution boundary:** no supported API, product, target, dependency, CocoaPods subspec, entitlement, privacy declaration, lifecycle feature, process lease, UI, Keychain, persistence, reconnection, or performance collection was added.

## Current-Diff Validation

- Focused SDK: 166 passed, 0 failed (`SDKSessionAdmissionTests`: 71; `NearWireBufferTests`: 26).
- Complete strict-concurrency package with warnings as errors: 361 passed, 0 failed.
- iOS Simulator package: 361 total, 360 passed, 1 platform-expected skip, 0 failed.
- Platform-neutral Core parity: 193 passed, 0 failed.
- Production TLS active session: 1 passed, 0 skipped, 0 failed.
- CocoaPods 1.16.2: lint and Core/SDK/UI/Performance subspec builds passed; only the documented placeholder-URL warning remains.
- Boundary, structure, English scan, format, version, validation-tool, strict OpenSpec, and diff-whitespace gates passed.

Exact commands, timestamps, environment identity, counts, and expected notes are recorded in `active-pump-focused.md`, `validation-gates.md`, and `run-identity.md`.

## Independent Review Closure

- Architecture/API: Round 5, 0 unresolved findings.
- Correctness/testing: Round 5, 0 unresolved findings.
- Security/performance/documentation: Round 6, 0 unresolved findings.

Earlier findings and their remediations remain preserved in the review directory. The final fresh rounds reviewed the complete current diff after the last production changes.

## Residual Scope

The active pump intentionally remains repository-internal. Supported `connect`/`disconnect`, process-lease orchestration, supported state/error publication, and public lifecycle behavior remain assigned to the next roadmap change, `sdk-public-connect`. This is an explicit downstream capability boundary, not missing work from this change.

## Conclusion

All implementation tasks and evidence obligations for `sdk-active-event-pump` are satisfied. The change is ready for strict validation, OpenSpec archival, and commit before any `sdk-public-connect` apply work begins.
