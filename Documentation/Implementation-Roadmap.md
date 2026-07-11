# NearWire Implementation Roadmap

NearWire is delivered as sequential OpenSpec changes. Only one change may be in apply or remediation at a time. Each change must be specified, implemented, tested, independently reviewed across all required dimensions, remediated, re-reviewed to zero unresolved findings, and archived before the next change enters apply.

## Change Sequence

### 1. `project-bootstrap`

Establish the repository layout, Swift Package and CocoaPods manifests, module markers, smoke tests, English documentation, validation scripts, and review gates.

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

### 8. `sdk-active-session`

Implement the process-wide connection lease, peer-to-peer-enabled TLS connection, hello and admission handshake, active route ownership, and negotiated flow policy without reconnection or background lifecycle behavior.

### 9. `sdk-connection-lifecycle`

Implement explicit disconnect, transient-failure classification, bounded reconnection, background transitions, lease release, route replacement, and final public connection-state behavior.

### 10. `sdk-ui`

Implement the optional injected-instance NearWireUI connection-code, status, error, and disconnect components without hidden SDK ownership or persistence.

### 11. `sdk-performance`

Implement opt-in one-second performance snapshots, supported public collectors, resource-safe start and stop behavior, keep-latest delivery, unavailable metric semantics, and overhead benchmarks.

### 12. `viewer-application-foundation`

Create the manually maintained NearWireViewer Xcode project and native SwiftUI application, automatic listener startup, TLS identity lifecycle, pairing-code display, default automatic admission, optional confirmation, and clean window shutdown.

### 13. `viewer-multidevice-flow-control`

Implement multi-device sessions, device identity and nicknames, one-to-many connection management, requested and effective rates, Bundle-ID preferences, queue telemetry, and device isolation tests.

### 14. `viewer-local-store-search`

Implement SQLite persistence, automatic sessions, 3 GiB and seven-day defaults, transactional cleanup, pinned-session protection, search indexing, JSON-path filters, pagination, and streaming JSON export.

### 15. `viewer-event-explorer-control`

Implement the three-column event explorer, single and merged timelines, receive-time ordering, detail inspection, renderers, pause-without-data-loss, simple Viewer-to-App control composition, and session causality display.

### 16. `viewer-performance-dashboard`

Implement performance projections, current metric cards, synchronized charts, gaps, unavailable metrics, time ranges, bucketed aggregation, and raw-event traceability.

### 17. `demo-distribution-e2e`

Create the manually maintained root Demo project, validate SPM and CocoaPods integration against one app implementation, exercise bidirectional events and performance collection, and run device-to-Viewer end-to-end suites.

### 18. `release-hardening`

Complete protocol compatibility matrices, security and resource-exhaustion tests, multi-device performance targets, packaging verification, API documentation, operator documentation, signing and distribution readiness, and the final requirement-by-requirement completion audit.

## Required Gate for Every Change

1. OpenSpec artifacts are complete and valid before apply.
2. Production behavior has automated tests and current English documentation.
3. Exact validation commands and results are saved under the active change.
4. Independent agents review architecture/API, correctness/testing, and security/performance/documentation.
5. Every finding is fixed and a fresh review round is completed.
6. The final round reports zero unresolved findings across every dimension.
7. The change is archived before the next change enters apply.
