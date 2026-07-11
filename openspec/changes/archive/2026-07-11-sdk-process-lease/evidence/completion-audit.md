# SDK Process Connection Lease Completion Audit

## `sdk-process-connection-lease`

- The production registry uses the exact permanent `com.nearwire.connection-lease.monitor` and `com.nearwire.connection-lease.owner` selector namespaces.
- Every loaded image resolves the process monitor through bounded `ProcessInfo.processInfo` bootstrap, then uses only the private monitor for claim and release.
- Selector resolution, candidate/token creation, and all outcome construction occur outside monitor-held regions as specified.
- Empty-slot claims return one opaque handle; successful-status contention returns the fixed contention error; every synchronization failure takes runtime-unavailable precedence.
- The non-configurable production registry always uses the Apple runtime adapter and process anchor. The low-level runtime seam is internal, non-SPI, and used with isolated fixtures only by tests.
- Two separately compiled and loaded dylibs prove shared monitor identity, cross-image mutual exclusion, exact release, stale cross-image safety, and reacquisition.

Status: proven.

## Exact Current-Handle Release

- Handles retain only the private monitor, exact token, and runtime adapter.
- Explicit and deinitialization release use the same idempotent exact-identity operation.
- Sequential, empty, repeated, concurrent, stale, ABA, and deinitialization behavior has deterministic coverage.
- Failed release enter leaves the owner untouched; failed release exit exposes no success or reacquisition guarantee.
- Race tests retain every possible winning handle until all workers join, and timeout cleanup cannot unlock the suite gate while work remains.

Status: proven.

## Bounded and Content-Safe State

- The lease retains no NearWire instance, event, queue, closure, continuation, task, timer, endpoint, pairing code, Viewer identity, or caller data.
- Error messages are computed exhaustively from a closed code; the whole-file initializer audit permits only one private code-only initializer.
- Handle and error description, debug description, interpolation, reflection, and Mirror output are fixed and content-free.
- Selector namespaces are documented as non-secret coordination identifiers; same-process Objective-C runtime code remains inside the trust boundary.

Status: proven.

## Explicit Ownership Boundary

- NearWire construction, send, streams, diagnostics, clear, and current disconnected shutdown never claim or release the process lease.
- Multiple idle instances preserve independent queue and stream state while an internal owner remains authoritative.
- No public connect, disconnect, lease, or synchronization API was added.
- No discovery run, network connection, TLS, Keychain, persistence, handshake, scheduler, task, timer, lifecycle observer, UI, or event transfer was introduced.

Status: proven.

## Validation and Distribution Boundary

- Wrapper sources, loader code, test runtime adapters, and generated dylibs remain outside SDK source globs and package products.
- The multi-image loader has a bounded watchdog and cleans every child process and temporary artifact.
- External SwiftPM and CocoaPods consumers cannot name the registry or any implementation type.
- SwiftPM objects and the linked CocoaPods-equivalent iOS binary export no harness wrapper symbol.
- Package product and target inventories, pod subspecs, supported API inventory, dependencies, entitlements, and privacy declarations remain unchanged.

Status: proven.

## Documentation, Validation, and Review

- English connection-lease architecture documentation covers lifetime, failure, trust, and distribution behavior.
- The roadmap now separates process lease, session admission, active event pump, public connect, and connection lifecycle.
- Focused strict-concurrency tests: 20 passed.
- iOS Simulator full suite: 246 passed.
- macOS Core harness: 165 passed.
- SwiftPM, CocoaPods, API inventory, symbol, package parity, module boundary, structure, English, formatting, version, validation-tool, and all 21 OpenSpec gates passed.
- Five post-implementation review rounds resolved every finding; the final architecture, correctness, and security reviews each report zero findings.

Status: proven.

## Audit Conclusion

Every requirement and scenario has implementation, deterministic test, packaging, documentation, validation, and independent review evidence. No task or finding remains unresolved. The change is ready for strict validation, archive, and commit before `sdk-session-admission` apply begins.
