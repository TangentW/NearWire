# Post-Implementation Security, Performance, and Documentation Review — Round 2

## Findings

### MEDIUM — The real-TLS gate can skip genuine listener regressions and is not exercised by the packaging path

Evidence:

- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1321-1369`
- `Core/Sources/NearWireTransport/SecureByteChannel.swift:531-562`
- `Scripts/verify-package.sh:550-570`
- `openspec/changes/sdk-session-admission/tasks.md:26-34`

The new integration test correctly constructs the production Viewer listener and App channel and exercises the admission exchange over a real TLS connection. However, it treats every pre-ready listener `.driverFailure` as proof that the test environment is restricted and skips the test. The production listener intentionally normalizes every `NWListener` failure, a ready-without-port condition, and an unknown listener state to that same code. A production listener regression therefore produces a passing suite with a skipped test instead of a failed TLS gate, even in the intended unrestricted validation environment.

The standard package verification path runs the SDK tests only against an iOS Simulator, where this test unconditionally skips under its non-macOS branch, and then runs only the Core harness on macOS. It consequently cannot establish that the real-TLS admission test executed rather than skipped. The current focused run demonstrated this ambiguity: 26 tests passed, one real-TLS test skipped, and the suite reported success.

Remediation:

- Permit this skip only through an explicit restricted-environment opt-in, rather than inferring restriction from a production `.driverFailure`. Without that opt-in, failure to obtain a listener port must fail the test.
- Add a dedicated unrestricted macOS production-TLS validation command or script that runs this test and rejects a skipped result. It may remain separate from `verify-package.sh`, but the required evidence must show that it executed to completion with zero skips.
- Save the exact command, unrestricted run identity, executed/skipped counts, and output under the active change's `evidence` directory before completing tasks 4.3, 5.2, or 5.3.

## Resolved Round 1 Findings

- Cancellation authority now transfers before the first post-discovery suspension. The core is initialized with the attempt token, persists cancellation while unbound, and refuses later bind/run startup after a terminal result. The deterministic transfer-barrier test passes.
- Every claimed policy pull now receives a reference-identity token. Delayed callbacks from immediate and rejected pulls cannot match a later waiter, and the deterministic ABA tests pass.
- Ingress uses a fixed eight-item actor-turn quantum and reschedules one drain turn. Event and byte accounting remains charged until an in-flight batch completes, so pending plus in-flight retention stays within the configured combined limit.
- Unsolicited discovery cancellation now maps to `discoveryFailed`; only locally authorized task or explicit cancellation maps to `cancelled`.
- Documentation continues to state the TLS non-authentication, public discovery metadata, no continuity, no replay-freshness, bounded-retention, cancellation, and ownership limitations accurately. No new sensitive diagnostic, unbounded retention, callback cycle, or public API exposure was found.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-sdk-session-admission-round2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-sdk-session-admission-round2-swiftpm swift test --disable-sandbox --filter SDKSessionAdmissionTests`: 27 executed, 26 passed, one real-TLS test skipped, zero failures.
- `ruby Scripts/check-session-admission-structure.rb .`: passed.
- `bash Scripts/verify-english.sh`: passed the automated CJK scan; semantic review was completed manually.
- `git diff --check`: passed.
- `openspec validate sdk-session-admission --strict`: passed; optional PostHog telemetry flush failed because network access was unavailable and did not affect validation.
- Static review of the active proposal, design, capability specs, tasks, complete session-admission source and tests, transport listener normalization, documentation, packaging path, and retained-state ownership graph.
