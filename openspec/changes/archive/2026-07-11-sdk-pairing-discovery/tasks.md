## 1. Pairing Code and Service Identity

- [x] 1.1 Implement NearWireInternal SPI Core values for the Sendable pairing code, shared Bonjour constants, ASCII-only normalization, fixed alphabet validation, redacted diagnostics, and exact service-name derivation.
- [x] 1.2 Implement shared `CryptoKit.SHA256` `ViewerDiscoveryDiscriminator` derivation and parsing without custom cryptography, canonical logical service identities with exact instance matching, fixed type, normalized local domain, required bounded `vid`, bounded interface observations, and no raw TXT or endpoint descriptions.
- [x] 1.3 Add exhaustive grammar, raw 64/65-byte and separator-heavy work bounds, separator, case, Unicode lookalike, bidi/control, canonical length, discriminator golden/case/reset vectors, identical-discriminator limitation, domain/type normalization, valid/missing/invalid/different `vid`, 32/33-interface identity equivalence, service-name, conflict-suffix, Sendable, interpolation, describing/reflecting, and redaction tests.

## 2. Driver-Independent Discovery Coordinator

- [x] 2.1 Implement the explicit operation/state table and one-shot async result contract for idle, searching, waiting, matched, ambiguous, failed, and cancelled outcomes.
- [x] 2.2 Implement run-before-driver ordering, repeated-run rejection, cancel-before-start, idempotent started cancellation, ready recovery, policy-denied terminal behavior, atomic complete-snapshot replacement, exact matching, logical deduplication, and terminal callback suppression.
- [x] 2.3 Add deterministic empty, unrelated, exact, LAN-plus-P2P duplicate, distinct-publisher ambiguity, valid-plus-missing/malformed `vid` blocking, ambiguity-with-unattributed precedence, identical-discriminator limitation, removed, successive replacement, reordered, bounded-snapshot terminal-event, waiting/snapshot/ready epoch, policy denial, start failure, unsolicited cancellation, late-callback, and lifecycle tests.
- [x] 2.4 Add reentrant-start, task-cancellation, cancellation/result races, exactly-once continuation completion, late-owner behavior, endpoint release, and no-retention tests without sleeps.

## 3. Network.framework Browser Adapter

- [x] 3.1 Implement the production TXT-enabled `_nearwire._tcp` local-domain browser with peer-to-peer inclusion and no fallback descriptor.
- [x] 3.2 Implement callback-edge raw-count and per-result conversion outcomes, readiness epochs, synchronous bounded `vid` extraction and metadata stripping, a bounded coalescing ingress with terminal priority, conservative safe error classification, atomic snapshot conversion, safe discard telemetry, and exact driver cancellation.
- [x] 3.3 Add inspectable production-plan, direct secure-channel endpoint compile integration, injected-driver, callback-storm/coalescing, ready ordering, hostile-name redaction, error-safety, 257-raw-duplicate pre-conversion rejection, oversized-after-valid callback-edge integration, exact-valid-plus-33-interface matching, two-valid-`vid` ambiguity with one 33-interface result, retained-byte/count, resource-bound, and deinitialization tests.

## 4. Integration Boundaries and Documentation

- [x] 4.1 Keep Core declarations behind NearWireInternal SPI and SDK declarations internal, and prove the supported SwiftPM/CocoaPods API inventory is unchanged.
- [x] 4.2 Update SDK documentation with `NSLocalNetworkUsageDescription`, `_nearwire._tcp` in `NSBonjourServices`, no direct-multicast entitlement, the reviewed no-privacy-manifest decision, pairing-code semantics, exact matching, `vid` derivation/linkability/limitations, P2P inclusion, lifecycle, and non-guarantees.
- [x] 4.3 Update the platform architecture with the exact shared `vid` derivation and refine the implementation roadmap into pairing-discovery, active-session, and connection-lifecycle changes without changing final product scope.
- [x] 4.4 Confirm this change adds no public connection API, TLS connection, process lease, persistence, Keychain access, handshake, rate scheduling, timer, background observer, UI, or event transfer.

## 5. Validation, Review, and Archive

- [x] 5.1 Restore the existing Core SPI checker executable bit required by the unchanged structure gate, then run focused discovery tests plus full iOS Simulator, macOS Core/SDK, strict-concurrency, CocoaPods, boundary, distribution, English, and OpenSpec gates.
- [x] 5.2 Capture exact commands, run identity, outputs, counts, expected notes, API inventory, and residual scope under the change evidence directory.
- [x] 5.3 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews and record every finding.
- [x] 5.4 Resolve every finding, add regressions, and repeat fresh multidimensional review rounds until all report zero unresolved findings.
- [x] 5.5 Complete the spec-to-evidence audit, mark every task complete, validate strictly, archive, and commit before active-session apply begins.
