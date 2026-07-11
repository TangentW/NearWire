# SDK Public API Completion Audit

## `sdk-event-api`

- NearWire-owned public signatures are implemented and compile through the canonical SwiftPM and CocoaPods consumer source.
- Codable dates, data, nested content, finite-number rules, decode failures, safe errors, keep-latest behavior, causal replies, cross-instance rejection, route affinity, and reserved namespaces have deterministic unit coverage.
- The API digester boundary proves supported signatures do not leak implementation modules.

Status: proven.

## `sdk-offline-buffer`

- Each NearWire instance owns one count- and byte-bounded memory queue.
- Tests prove monotonic TTL, wall-clock independence, priority overflow, coalescing, explicit clear, instance isolation, stable IDs, route drops, transport acceptance, transport rejection, and encoding deferral.
- Real `SecureByteChannel` mailbox integration proves an event leaves the SDK queue only after synchronous byte ownership transfer.

Status: proven.

## `sdk-async-facade`

- Tests prove immediate latest-state delivery, independent subscribers, bounded slow-consumer failure, cancellation cleanup, concurrent subscription/finish behavior, final shutdown state, post-shutdown terminal streams, and no continuation retention.
- Construction starts no task, timer, discovery, network, storage, Keychain, or UI behavior.

Status: proven.

## `sdk-public-boundary`

- One canonical consumer covers construction, configuration, send, decode, reply, streams, diagnostics, clear, and shutdown.
- The same source compiles for iOS 16 through SwiftPM and CocoaPods in Swift 5 language mode.
- Core declarations require `NearWireInternal` SPI in both separate-module and CocoaPods same-module layouts.
- Optional platform events use only the narrow `NearWireBuiltins` SPI.

Status: proven.

## Modified `bounded-event-queue`

- Transactional offer removes eligible work only after acceptance.
- Rejection preserves identity, ordinal, byte accounting, TTL, FIFO position, and weighted scheduler credit.
- Preflight route removal consumes bounded queue service without consuming transport bytes.
- Exhausted-cycle regressions prove scheduler credits are restored for admission and byte-budget stops.

Status: proven.

## Modified `secure-byte-channel`

- Synchronous nonisolated admission is serialized by one bounded mailbox lock.
- Concurrent tests prove count and byte bounds, FIFO, single in-flight send, atomic rejection, terminal close, payload release, and cleanup.
- Full platform tests prove the production TLS channel and trust path.

Status: proven.

## Distribution, Documentation, and Review

- SwiftPM, CocoaPods, iOS Simulator, macOS Core, strict concurrency, API inventory, boundary, English, validation-tool, and OpenSpec gates passed.
- English SDK, flow-control, transport-security, and distribution documentation describe behavior and non-guarantees.
- Every recorded review finding has a corresponding implementation or test resolution.
- The fifth review round reports zero unresolved findings in all three required dimensions.

Status: proven.

## Audit Conclusion

Every requirement and scenario in this active change has direct implementation, test, packaging, documentation, and review evidence. No requirement remains incomplete or indirectly inferred. The change is ready to archive and commit before the next SDK change begins.

