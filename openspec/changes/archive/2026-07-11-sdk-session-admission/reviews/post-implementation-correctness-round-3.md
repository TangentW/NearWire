# Post-Implementation Correctness Review — Round 3

Reviewed the current session-admission implementation, the complete admission test suite, the Round 2 finding, the active specifications and design, and the real-TLS packaging gate.

## Result

ZERO FINDINGS

The Round 2 protocol and source-to-error matrix finding is resolved.

## Verified Remediation

- `testExhaustiveAcknowledgementAndMalformedControlMatrix` drives every case through the admission boundary and expects the closed `protocolViolation` result (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:757-869`).
- The acknowledgement matrix independently substitutes selected version, selected codec, maximum event bytes, capabilities, send policies, and Viewer installation ID (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:775-835`). Each mutation differs from the negotiated baseline and is encoded as a structurally valid acknowledgement before admission rejects it.
- The invalid session epoch case preserves the encoded frame shape while replacing the UUID text with a same-length non-UUID value, so failure occurs during admission decoding/route validation rather than test construction (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:837-848`).
- Unknown Control type, malformed JSON, malformed ping payload, and an oversized Control frame declaration are separate admission-boundary cases (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:849-868`).
- `testGenuineSecondRunReturnsAlreadyStarted` keeps the first attempt active through channel startup, invokes a second `run()`, proves `alreadyStarted`, and then cancels and verifies the first attempt independently (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:871-880`).
- Existing incompatibility coverage still proves wrong peer role plus disjoint version, codec, and send-policy negotiation (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:697-731,1335-1381`).

## Implementation Re-audit

- Admission still arms the attempt token and permanent core before channel construction, so the prior transfer-cancellation race remains closed (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:153-178`; `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:156-205`).
- Policy pulls still allocate one reference-identity token per claimed gate and compare by identity, so the prior ABA race remains closed (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:267-305`).
- Bounded ingress still accounts in-flight batches until completion, processes only one eight-item quantum per actor turn, reschedules at most one drain, and preserves terminal priority (`SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:62-146`; `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:104-105,212-232`).
- Discovery `.cancelled` without local cancellation authority still maps to `discoveryFailed`, while explicit/task cancellation retains the expected `cancelled` result (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:129-143,263-288`).
- Wire, transport, protocol, ownership, and pull outcomes remain mapped to the closed code-only error type; no reviewed path returns an admitted handle after any new malformed-matrix case.

## Real-TLS Packaging Gate

- `Scripts/verify-package.sh:572-589` runs exactly `SDKSessionAdmissionTests.testRealTLSProductionChannelCompletesAdmissionSequence` from the package harness with the Swift sandbox disabled.
- The gate rejects a skipped test and also requires the XCTest summary to contain exactly one passing test. A normal skipped summary containing `1 test skipped` does not satisfy the passing-summary predicate.
- The exact filter was executed during this review and selected one test. It completed a real TLS App/Viewer admission exchange and passed.

## Validation

```text
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --scratch-path /tmp/nearwire-round3-build --filter SDKSessionAdmissionTests
```

PASS — 29 tests, 0 failures, including the exhaustive malformed-control matrix, genuine second-run case, transfer-cancellation barrier, stale-pull-token cases, and real-TLS admission.

```text
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --scratch-path /tmp/nearwire-round3-build --filter SDKSessionAdmissionTests.testRealTLSProductionChannelCompletesAdmissionSequence
```

PASS — exactly 1 test selected and executed, 0 failures, not skipped.

```text
bash -n Scripts/verify-package.sh
```

PASS — packaging script syntax is valid; the skipped-summary rejection predicate was also checked directly.
