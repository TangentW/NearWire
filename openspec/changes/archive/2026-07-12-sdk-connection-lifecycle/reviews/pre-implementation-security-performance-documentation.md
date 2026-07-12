# SDK Connection Lifecycle Pre-Implementation Security, Performance, and Documentation Review

## Result

**Unresolved actionable finding count: 6** — three High, two Medium, and one Low.

The proposal correctly keeps recovery opt-in, preserves mandatory TLS and exact lease ownership, forbids persistence/observers/background requests, uses safe closed errors, and keeps SwiftPM/CocoaPods dependency boundaries unchanged. The following ownership and resource contracts need resolution before implementation.

## Findings

### 1. High — No valid owner can create the post-success intent under the stated pairing-release rules

**Evidence**

- `design.md:44-50` says the lifecycle intent containing the normalized code exists only after explicit connection becomes active and that the current route does not retain the code.
- `specs/sdk-public-connect/spec.md:32-44` requires the public attempt to release its normalized code immediately after admission construction and says only after connected commit may the actor install a separate intent copy.
- The current base contract already requires attempt release at admission and admission release at discovery ownership (`openspec/specs/sdk-public-connect/spec.md:80-86`).
- The current pipeline consumes `SDKPairingCodeTransfer` when admission is constructed (`SDK/Sources/NearWire/NearWire.swift:682-700`); neither the connected owner nor terminal coordinator contains a code.

**Impact**

At connected commit there is no specified source from which to create the new intent. An implementation would have to retain the raw `connect(code:)` argument or another hidden normalized copy across admission, recover the code from a derived Bonjour name, or make a route owner return it. Each option contradicts the minimal-retention contract and risks pairing data surviving failure paths.

**Recommended change**

Define one actor-owned **pending intent capsule** created after pairing validation and before admission. It may retain the single lifecycle copy while the separate one-shot admission transfer owns only the discovery copy. Connected commit must promote the same capsule without copying; every initial failure, disconnect/suspend winner, Task cancellation, shutdown, and stale generation must clear it. Update the specs to acknowledge this pending lifecycle owner, explicitly forbid reparsing the raw method argument or deriving the code from Bonjour state, and require retention tests at reservation, admission transfer, connected promotion, and every failed-connect boundary.

### 2. High — A per-interruption attempt limit still permits unbounded P2P recovery under route flapping

**Evidence**

- `design.md:28-36` bounds attempts after a previously active connection or explicit resume, and `specs/sdk-connection-lifecycle/spec.md:3-17` applies the budget to one interruption.
- Successful recovery clears retry progress (`design.md:109-125,127-133`), after which another active terminal condition can start a new interruption budget.
- `design.md:40-42` says infinite recovery was rejected because it can retain the code and schedule work indefinitely, while `proposal.md:8-10` describes recovery and code lifetime as bounded.
- V1 deliberately has no jitter (`design.md:34`), so many phones connected to one Viewer can also synchronize every retry after a shared outage.

**Impact**

A faulty or malicious Viewer can repeatedly reach active state and immediately close, resetting a 20-attempt campaign indefinitely. The SDK can therefore retain the pairing intent and repeatedly run peer-to-peer Bonjour, TLS, Keychain reads, admission, and pump setup for process lifetime despite claiming infinite recovery is excluded. Synchronized no-jitter retries amplify energy and connection spikes across multiple phones.

**Recommended change**

Add a normative cross-interruption budget. For V1, the simplest strong bound is a total automatic-attempt budget owned by the lifecycle intent and reset only by an explicit host action (`connect` or `resume`), not by a brief recovered connection. If the product needs automatic budget reset, specify a minimum stable-connected interval plus a maximum attempts-per-window rule and bounded jitter/decorrelation. Add a deterministic flap test in which each recovery reaches connected and immediately receives `remoteClosed`; prove work stops, intent clears, and no Task/timer remains at the global budget.

### 3. High — Cancelled recovery Tasks can outlive intent, retain the code, and accumulate

**Evidence**

- `design.md:127-131` makes the delay Task hold a copied normalized pairing code across sleep while the actor also retains the intent.
- Disconnect, suspension, supersession, success, failure, exhaustion, and shutdown only “cancel” stale delay work (`design.md:64-66`; `specs/sdk-connection-lifecycle/spec.md:5-7`).
- The async-facade delta says deinitialization “release[s] ... the recovery Task so cancellation” (`specs/sdk-async-facade/spec.md:5-7`), but releasing a Swift `Task` handle does not cancel the underlying Task, and Task cancellation is cooperative.
- The resource requirement promises at most one recovery Task and code clearing at terminal intent boundaries (`specs/sdk-connection-lifecycle/spec.md:24-38,137-144`).

**Impact**

If sleep is delayed or does not promptly cooperate with cancellation, dropping the actor's handle leaves a live Task that still retains the pairing code. A later resume/recovery can create a successor while the stale Task remains alive; repeated suspend/resume or supersession can accumulate Tasks beyond the claimed bound. Actor deinitialization has the same problem and can leave delay work alive for up to the 300-second cap or longer under an injected/nonconforming dependency.

**Recommended change**

The delay Task must capture no pairing code, endpoint, metadata, route, or actor; it should carry only generation, attempt, delay, and a cancellation owner. On wake, it should weakly enter the actor and obtain the token-current intent only for immediate connection construction. Specify a cancellation-completion handshake: disconnect, suspend, shutdown, and replacement must invalidate first and must not install a successor delay until the prior Task has acknowledged termination. Explicitly cancel in deinitialization rather than relying on handle release. Define the sleep dependency as cancellation-cooperative and test an intentionally held/noncooperative sleep, actor deinit, repeated suspend/resume, live Task count, and weak pairing-storage release.

### 4. Medium — “Bounded cleanup waiters” has no enforceable bound or cancellation policy

**Evidence**

- `design.md:70-81` proposes an actor-owned collection of cleanup waiters joined by concurrent disconnect/suspend calls.
- `specs/sdk-connection-lifecycle/spec.md:40-59` allows arbitrarily many concurrent disconnect callers to join one cleanup boundary.
- `specs/sdk-connection-lifecycle/spec.md:137-144` promises a bounded list but defines no maximum, overflow outcome, waiter coalescing representation, or removal behavior when a waiting caller Task is cancelled.
- `tasks.md:29-30` asks for bounded cleanup-waiter tests without identifying the bound to test.

**Impact**

Application code can create an unbounded number of suspended continuations while terminal cleanup or non-cancellable identity work is delayed. Cancelled caller Tasks may remain retained until cleanup, making the public idempotent API an avoidable memory-amplification surface.

**Recommended change**

Avoid an actor-owned per-caller array: define one generation-scoped cleanup completion object/Task and make callers await that shared result with cancellation-aware waiter removal. If per-caller storage is unavoidable, specify a hard count and a deterministic content-safe saturation behavior compatible with the nonthrowing API. Clarify whether caller cancellation may return before cleanup or whether the API deliberately ignores cancellation; test the chosen contract with many concurrent and cancelled callers while cleanup is held.

### 5. Medium — The transient error set retries deterministic clock and undifferentiated TLS failures

**Evidence**

- `design.md:83-91` and `specs/sdk-connection-lifecycle/spec.md:82-96` classify `clockFailed` and unexpected `transportFailed` as transient.
- The current closed code `transportFailed` covers secure-channel start/readiness and other transport operations (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:764-802,873-878`), so it does not distinguish a temporary established-channel I/O failure from a repeatable TLS certificate/trust/ALPN failure.
- `clockFailed` is produced by local scheduling, queue, and token-bucket/clock paths throughout the active core (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:617-683,1278-1326,1445-1454,1687-1721`); a fresh P2P route does not repair the local clock source.
- Mandatory TLS must never be weakened or bypassed after validation failure (`Documentation/Transport-Security.md:17-32,40-48`).

**Impact**

An invalid TLS peer/configuration or deterministic local clock failure can consume the full discovery and handshake retry budget with no plausible recovery, wasting radio/CPU and creating a repeated security-validation workload. Keeping one broad public error is safe, but using the same broad internal code for retry disposition is not precise enough.

**Recommended change**

Keep public errors content-safe while adding closed internal disposition detail: distinguish pre-ready TLS trust/identity/ALPN failure, local clock/invariant failure, and established-channel transient I/O termination. Treat TLS validation and clock failure as permanent for automatic recovery; allow a later explicit host resume if desired. Add an exhaustive table test proving every internal code and phase has exactly one disposition and that no TLS validation failure can trigger retry or plaintext fallback.

### 6. Low — Disconnect status documentation is internally contradictory

**Evidence**

- `design.md:64-68` and `specs/sdk-connection-lifecycle/spec.md:40-45` define disconnect from disconnected as a no-op.
- `design.md:109-111` and `specs/sdk-connection-lifecycle/spec.md:98-104` say manual disconnect clears `lastError`.

**Impact**

After permanent failure or recovery exhaustion, a disconnected instance can carry `lastError`. The plan does not say whether a subsequent disconnect preserves that snapshot as a no-op or mutates it to clear the error, so public status behavior and documentation cannot both be implemented as written.

**Recommended change**

Choose one rule and state it in both requirements. Prefer defining “no-op” as no connection/ownership work while allowing one coherent status update that clears `lastError`, or explicitly preserve the error until connect/resume success. Add a late-subscriber status test for the chosen behavior.

## Final Verdict

**Not ready for implementation.** The change has strong security and distribution intentions, but pairing ownership is currently unrealizable without hidden retention, recovery is not globally energy bounded, and Task/waiter lifetime bounds are not yet enforceable. Resolve Findings 1-4 in the normative design/specs and address the retry classification and status contradiction before marking the pre-implementation review gate complete.

