# Post-Implementation Correctness Review — Round 2

Reviewed the current session-admission implementation, tests, proposal, design, capability specifications, and task state after the Round 1 remediation. The two prior HIGH findings are resolved: cancellation authority is armed before channel construction and persists across the transferred-but-unbound interval, and every claimed policy pull now receives a reference-identity token that prevents ABA reuse. The bounded ingress drain, terminal precedence, unsolicited discovery-cancellation mapping, and production real-TLS admission composition were also reassessed.

## Finding

### MEDIUM — The required protocol and source-to-error matrix remains incomplete

**Evidence**

- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:33-35` requires exact acknowledgement equality across version, codec, maximum event bytes, capabilities, policies, Viewer installation ID, and a syntactically valid session epoch, and requires unknown type, malformed payload, oversized frame, incompatible negotiation, unregistered codec selection, substitution, and escalation to fail terminally.
- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:184-186` and `openspec/changes/sdk-session-admission/design.md:175-206` define a closed source-to-code table, including `alreadyStarted` for a second run and exact mappings for every wire, discovery, transport, deadline, ownership, and pull outcome.
- `openspec/changes/sdk-session-admission/design.md:236-241` explicitly requires protocol coverage for future codec selection, acknowledgement substitution, unknown type, malformed JSON, oversized frame, and every source-to-code row.
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:697-753` exercises a wrong-role hello and only one acknowledgement mismatch (`maximumEventBytes`). `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1210-1256` adds version, codec, and policy incompatibility, but does not cover the remaining acknowledgement fields, invalid session epoch, unregistered selected codec, unknown Control type, oversized frame, or malformed JSON through the admission boundary.
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:106-115` calls `run()` after cancel and therefore observes `cancelled` twice; it does not prove that a genuine second run maps to `alreadyStarted`.
- `openspec/changes/sdk-session-admission/tasks.md:25` correctly leaves task 4.2 unchecked.

**Impact**

The implementation may currently map these cases correctly through lower-level codecs, but the admission composition does not yet have the deterministic evidence required by its own closed error contract. A later change in codec registration, acknowledgement validation, or admission error mapping could regress to the wrong code or return a partial admission result without failing this suite.

**Required remediation**

Add data-driven admission-boundary tests for every acknowledgement field substitution, invalid epoch, unregistered selected codec, unknown type, malformed JSON/payload, oversized frame, and an actual concurrent or completed second `run()` that returns `alreadyStarted`. Complete the remaining source-to-code rows and mark task 4.2 only after the exhaustive matrix passes.

## Verified Remediations and Reassessments

- **Transfer cancellation:** `SDKSessionAdmission` creates and installs the attempt token and permanent core, records `transferred`, and clears admission-owned hello state before channel construction (`SDKSessionAdmission.swift:153-172`). The core starts armed with that token and latches cancellation before bind or run (`SDKSessionTransportCore.swift:156-205`). `testCancellationPersistsAcrossTransferredButUnboundCore` uses an explicit pre-bind barrier and proves one `cancelled` result with no channel start (`SDKSessionAdmissionTests.swift:1059-1092`). The prior HIGH race is resolved.
- **Pull ABA:** each claimed pull allocates a distinct `SDKSessionPullToken`, and stale callbacks can match only by reference identity (`SDKSessionTransportCore.swift:267-305`). `testUniquePullIdentityIgnoresDelayedImmediateAndConcurrentCancellation` deterministically delays stale callbacks from both immediate-FIFO and `pullAlreadyPending` outcomes before installing newer waiters (`SDKSessionAdmissionTests.swift:1094-1172`). The prior HIGH race is resolved.
- **Ingress quantum and accounting:** one actor turn processes at most eight ingress items, retained counts include batches until `completeBatch`, and each turn reschedules at most one drain (`SDKSessionTransportCore.swift:104-105,212-232`; `SDKSessionChannelIngress.swift:102-139`). Terminal latching discards pending nonterminal work while preserving in-flight accounting (`SDKSessionChannelIngress.swift:62-99,119-127,141-146`).
- **Unsolicited discovery cancellation:** a lower-layer `.cancelled` maps to `discoveryFailed` unless explicit/task cancellation authority supplies the cancellation outcome (`SDKSessionAdmission.swift:129-143,263-288`), with the discovery category matrix covering the unsolicited case (`SDKSessionAdmissionTests.swift:895-920`).
- **Terminal priority:** ingress terminal latching replaces queued nonterminal callbacks, and the core checks a latched terminal before each item and before provisional admission commit (`SDKSessionChannelIngress.swift:70-86`; `SDKSessionTransportCore.swift:218-231,381-387`).
- **Production TLS composition:** `testRealTLSProductionChannelCompletesAdmissionSequence` starts a real secure Viewer listener, constructs the App channel through `SecureAppTransport`, exchanges App/Viewer hello and acknowledgement bytes, validates the admitted route, and performs deterministic cleanup (`SDKSessionAdmissionTests.swift:1303-1419`). It passed in this review run.

## Validation

Command:

```text
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --scratch-path /tmp/nearwire-round2-build --filter SDKSessionAdmissionTests
```

Result: PASS — 27 tests, 0 failures, including the deterministic transfer-cancellation and stale-pull-token tests and the real-TLS production-channel admission test.
