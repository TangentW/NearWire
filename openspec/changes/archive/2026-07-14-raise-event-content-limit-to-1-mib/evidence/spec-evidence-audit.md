# Spec-to-Evidence Audit

Date: 2026-07-15 (Asia/Shanghai)

## Reviewed Default Byte Domains

| Domain | Default | Meaning |
| --- | ---: | --- |
| Canonical deterministic JSON content | 1,048,576 bytes | Fixed product maximum; actual content bytes are encoded and retained |
| Internal tagged Event model | 4,259,840 bytes | Conservative safety bound for queue accounting |
| Offline queue total | 16,777,216 bytes | Bounded total accounted memory |
| Exact maximum V1 Event record | 1,049,539 bytes | Content plus maximum deterministic metadata envelope |
| Event-lane payload | 2,097,152 bytes | Capacity for the record plus V1 message wrapper |
| Secure-channel single send | 2,097,157 bytes | Event-lane payload plus five frame bytes |
| Active SDK outbound accounting turn | 4,259,840 bytes | Services one maximum-accounted queued Event |
| Wire payload hard ceiling | 16,777,216 bytes | Unchanged denial-of-service bound |

## Requirement Traceability

| Requirement or scenario | Implementation evidence | Test evidence | Result |
| --- | --- | --- | --- |
| Accept exactly 1 MiB canonical content | `EventValidationLimits.default` is 1,048,576 bytes | `testDefaultContentLimitIsExactlyOneMiB` | Pass |
| Reject one byte over before mutation | Event validation runs before SDK queue admission | `testDefaultBufferAcceptsOneMiBContentAndRejectsOneByteOverAtomically` compares queue contents, bytes, and statistics | Pass |
| Preserve dynamic sizing | Validation and deterministic encoders operate on actual values; no maximum-size buffer was introduced | Small-event suites remain green and exact-content tests compare actual encoded counts | Pass |
| Bound internal queue accounting | Derived model and single-Event bounds are 4,259,840 bytes; total is 16 MiB | Queue and public configuration default assertions | Pass |
| Carry one maximum Event record and frame | Protocol default derives the exact record bound; Event lane is 2 MiB | `testProductionDefaultsCarryExactlyOneMiBContentThroughOneEventFrame` and exact-boundary session-codec traversal | Pass |
| Retain conservative peer negotiation | Hello offers remain hard-bounded and negotiation still selects the smaller offer | Pre-handshake larger-peer regression and hard-bound rejection | Pass |
| Viewer uses production defaults | Viewer constructs admission and active codecs from shared defaults | Manager-level production-offer handoff and complete Viewer suite | Pass |
| SDK active session can service the new queue default | Active outbound quantum equals the SDK single-Event accounting bound | Active-limit equality assertion and all 74 SDK session-admission tests | Pass |
| Explicit smaller configurations remain valid | An omitted single-Event limit clamps to an explicitly smaller total; explicit incoherent limits still reject | `testExplicitSmallerBufferTotalClampsOmittedSingleEventLimit` plus custom-buffer and negotiation tests in the 545-test suite | Pass |
| Hard ceilings remain unchanged | Validation and wire hard maximums were not widened | One-byte-over content, wire-hard-bound, queue, and transport limit tests | Pass |

All scenarios have direct implementation and test evidence. The only full Viewer-suite limitation
is the separately recorded entitlement assertion for an intentionally unsigned test application.
