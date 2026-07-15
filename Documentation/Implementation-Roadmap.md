# NearWire Implementation Roadmap

NearWire is delivered as sequential OpenSpec changes. Only one change may be in apply or remediation at a time. Each change must be specified, implemented, tested, independently reviewed across all required dimensions, remediated, re-reviewed to zero unresolved findings, and archived before the next change enters apply.

## Change Sequence

### 1. `project-bootstrap`

Establish the repository layout, Swift Package and CocoaPods manifests, module markers, smoke tests, English documentation, and review gates based on maintained product tests and standard toolchain commands.

### 2. `core-event-model`

Implement JSON-compatible values, event identifiers, metadata, Codable payload conversion, validation limits, built-in event namespaces, correlation, and performance snapshot schemas.

### 3. `core-flow-control`

Implement bounded byte-and-count queues, normal delivery, keep-latest coalescing, TTL expiration, priority-aware overflow, token buckets, batching, clocks, and deterministic tests.

### 4. `core-wire-protocol`

Implement protocol envelopes, control and event lanes, length-prefixed framing, version and capability negotiation, sequence epochs, error frames, and golden compatibility fixtures.

### 5. `core-transport-security`

Implement Network.framework transport building blocks, mandatory TLS configuration, Viewer self-signed identity support, iOS trust behavior, no-plaintext downgrade guarantees, and fault-injection tests.

### 6. `sdk-public-api`

Implement the instance-based `NearWire` facade, configuration, Swift concurrency state and event streams, Codable send and decode APIs, offline memory buffering, replies, errors, lifecycle isolation, and equivalent SwiftPM/CocoaPods public API consumer compile fixtures.

### 7. `sdk-pairing-discovery`

Implement bounded pairing-code normalization, exact Bonjour identity, shared `vid` derivation, peer-to-peer-enabled browsing, deterministic one-shot selection, safe diagnostics, and host local-network integration documentation.

### 8. `sdk-process-lease`

Implement the internal process-wide exact-owner connection lease across independently loaded NearWire images, including bounded bootstrap, safe contention, stale-handle protection, and no public connection API.

### 9. `core-wire-prehandshake-codec`

Add the fixed V1 bootstrap codec that exchanges only hello, safe error, and disconnect before a negotiation result exists, with lane-first rejection, version-confusion prevention, sealed typed results, and no channel lifecycle.

### 10. `sdk-session-admission`

Compose pairing discovery, peer-to-peer-enabled TLS connection, hello and admission handshake, discovery-to-hello Viewer identity consistency, admitted route ownership, and negotiated capabilities behind internal session admission. Event transfer remains inactive.

### 11. `sdk-active-event-pump`

Implement outbound queue draining, incoming event delivery, sequence validation, active-route affinity, negotiated flow policy, and bounded transport backpressure for one admitted session. This internal layer is implemented and is composed by item 12.

### 12. `sdk-public-connect`

Expose explicit instance-based connection entry points, claim the process lease, map every internal admission and ownership failure to safe public errors, and publish connection state without reconnection or background behavior.

Implemented: the supported `connect(code:)` path composes device-local installation identity, discovery, mandatory TLS admission, initial flow policy, one terminal coordinator, safe public errors, and exact public states. Lifecycle operations and recovery are composed by item 13.

### 13. `sdk-connection-lifecycle`

Implement explicit disconnect, transient-failure classification, bounded reconnection, background transitions, exact-handle release, route replacement, and final public connection-state behavior.

Implemented: async disconnect waits for exact cleanup; host-controlled suspend/resume adds no automatic platform observer; default-disabled recovery uses a total intent-wide budget, fresh routes, safe phase-aware failure classification, and latest-value connection status.

### 14. `sdk-ui`

Implement the optional injected-instance NearWireUI connection-code, status, error, and disconnect components without hidden SDK ownership or persistence.

Implemented: the two-view public surface injects an existing instance, bounds pairing input in memory, renders complete accessible state, and coordinates simultaneous panels without duplicate Connect or Disconnect work. Disappearance stops UI observation and pending UI attempts without disconnecting an active host-owned session.

### 15. `sdk-performance`

Implement opt-in one-second performance snapshots, supported public collectors, resource-safe start and stop behavior, keep-latest delivery, unavailable metric semantics, and overhead benchmarks.

Implemented: the optional monitor exposes only configuration, safe errors, lifecycle state, and explicit start/stop; public iOS collectors project conservative process/display/device/buffer metrics into the internal V1 schema; unavailable values and battery ownership are total; ordinary keep-latest delivery, two-component privacy manifests, exact cleanup barriers, packaging consumers, and deterministic overhead gates are covered.

### 16. `viewer-application-foundation`

Create the manually maintained NearWireViewer Xcode project and native SwiftUI application, automatic listener startup, TLS identity lifecycle, pairing-code display, default automatic admission, optional confirmation, and clean window shutdown.

Implemented: the native macOS 13 application provides one main Event window and one singleton auxiliary Performance window over the same runtime. It automatically prepares separate persistent installation and TLS identities, publishes an exact memory-only pairing service, handles bounded collision-safe listener replacement, admits at most 32 peers through one continuous connection core and 10-second deadline, supports optional approval and pause, fails closed with fixed recovery, and packages the exact sandbox, local-network, and privacy metadata.

### 17. `viewer-multidevice-flow-control`

Implement multi-device sessions, device identity and nicknames, one-to-many connection management, requested and effective rates, Bundle-ID preferences, queue telemetry, and device isolation tests.

Implemented: the Viewer owns at most 16 exact connection sessions through cleanup, rejects duplicate unauthenticated logical routes, retains 64 short-lived recent rows, negotiates conservative directional policy, exchanges bounded bidirectional Events with atomic mailbox admission and receive backpressure, persists only bounded requested preferences and nicknames, and presents content-free per-device telemetry.

### 18. `viewer-local-store-search`

Implement SQLite persistence, automatic sessions, 3 GiB and seven-day defaults, transactional cleanup, pinned-session protection, search indexing, JSON-path filters, pagination, and streaming JSON export.

### 19. `viewer-event-explorer-control`

Implement the three-column event explorer, single and merged timelines, receive-time ordering, detail inspection, renderers, pause-without-data-loss, simple Viewer-to-App control composition, and session causality display.

### 20. `viewer-performance-dashboard`

Implement performance projections, current metric cards, synchronized charts, gaps, unavailable metrics, time ranges, bucketed aggregation, and raw-event traceability.

### 21. `demo-distribution-e2e`

Create the manually maintained root Demo project, validate SPM and CocoaPods integration against one app implementation, generate the aggregate Xcode App privacy report, exercise bidirectional events and performance collection, and run device-to-Viewer end-to-end suites.

### 22. `release-hardening`

Complete protocol compatibility matrices, security and resource-exhaustion tests, multi-device performance targets, packaging verification, API documentation, operator documentation, signing and distribution readiness, and the final requirement-by-requirement completion audit.

The final release gate must execute the Viewer A/unrelated/B stable-signer XCTest sequence documented in `Viewer-Foundation.md` with two valid, unrelated code-signing identities. Earlier changes preserve the executable gate and may record an environment deferral, but release hardening cannot complete while that cross-update Keychain evidence remains pending.

## Required Gate for Every Change

1. OpenSpec artifacts are complete and valid before apply.
2. Production behavior has automated tests and current English documentation.
3. Exact validation commands and results are saved under the active change.
4. Independent agents review architecture/API, correctness/testing, and security/performance/documentation.
5. Every finding is fixed and a fresh review round is completed.
6. The final round reports zero unresolved findings across every dimension.
7. The change is archived before the next change enters apply.
