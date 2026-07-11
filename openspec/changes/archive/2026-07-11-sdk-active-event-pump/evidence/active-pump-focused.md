# Active Pump Focused Evidence

## Implementation Coverage

- One side-effect-free one-shot starter binds an admitted attachment to one exact `NearWire` owner and returns a cancellation-owning lifetime handle after initial policy activation.
- One non-owning one-shot termination observer has independent per-wait cancellation.
- The permanent session core, ingress, secure channel, decoder, codec, route, relay, and terminal cleanup remain unchanged owners across admission and active phases.
- Viewer policy offers are capped independently by App uplink and downlink maxima. Initial acceptance precedes active state; later complete bidirectional updates use a fresh bound-owner clock and install only after mailbox admission.
- App Events remain in the existing bounded `NearWire` queue until reserved secure-mailbox admission and exact gate-authorized removal commit together.
- Viewer Events pass active decoding, route and sequence validation, receiver-local TTL conversion, bounded FIFO/indexed-deadline admission, and gate-authorized publication.
- Callback decode, queue mutation, incoming publication, policy transactions, tasks, one-shot wakes, and retained bytes all have explicit positive bounds.

## Focused SDK Run

- Command: `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-cache swift test --filter NearWireTests`
- Finished: 2026-07-12 04:03:12 +08:00.
- Result: 166 SDK-target tests executed, 166 passed, 0 skipped, 0 failed in 0.253 seconds.
- `SDKSessionAdmissionTests`: 71 passed, 0 failed, including conservative initial and dynamic policy, fresh-clock reversal, owner-signal-storm policy priority, binding cancellation and both no-offer deadlines, runner/pull ownership, final-handle and observer cancellation winners, named mailbox-completion/observer-cancellation/terminal-close hooks, zero/fractional/one/burst captured uplink allowance, committed-prefix stale-result rejection, downlink publication gate winners and stale-result rejection, publication-time policy order/overflow, slow-subscriber isolation, route/direction rejection, ingress parking, exact incoming FIFO/heap and in-flight bounds, controlled no-poll backpressure proof, completion-before-blocked-result, deferred policy after a blocked result, fail-closed complete-frame quantum with a fragmented successor, level-triggered owner shutdown across in-flight live/unavailable refresh results, exact heterogeneous batch accounting, shared expiry/publication quantum, complete Event-frame cross-limits, cancellation precedence, and saturating diagnostics.
- `NearWireBufferTests`: 26 passed, including owner shutdown, atomic tokenized wake registration with a nonmutating initial snapshot, named per-expiration/candidate/route/Event-mailbox hooks, gate winner ordering, origin-clock TTL, reserved-mailbox backpressure, retry identity, accepted-only sequence commit, representative token/service/byte/depth/mailbox cases, and the 81-case burst-allowance Cartesian limiter matrix.

## Focused Core Runs

- `BoundedEventQueueTests`: 37 passed, including nonmutating active preview plus active scheduling and offering bounds.
- `SecureByteChannelTests`: 28 passed, including reserved admission and capacity progress.
- `WireFrameTests`: 11 passed, including the primitive decoder's exact bounded-remainder behavior used by the active core to detect callback work overflow. Active-core exact-limit and one-over-limit behavior is covered by `testActiveFrameQuantumFailsClosedWithoutContinuationChain`.
- `NearWireTransportTests`: 95 passed in the final full run, including mandatory production TLS.

## Production TLS Active Session

- Command: `./Scripts/verify-package.sh` production TLS active-session sub-gate.
- Finished: 2026-07-12 04:00:38 +08:00.
- Result: 1 passed, 0 skipped, 0 failed.
- Coverage: production Viewer listener and App channel, TLS 1.3 admission handoff, policy activation, one Event in each direction, App queue drain, and explicit teardown without live Bonjour discovery.

## Determinism

Race-focused tests use lock-controlled gates, synchronous operation hooks, controlled discovery, actor barriers, exact clocks, and identity tokens. No active-pump correctness assertion depends on a live Bonjour browser or probabilistic network discovery. Existing polling helpers are used only to observe already-deterministic state transitions and have explicit one-second test timeouts.
