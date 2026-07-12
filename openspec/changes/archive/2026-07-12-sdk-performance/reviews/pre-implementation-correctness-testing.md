# Pre-Implementation Correctness and Testing Review

Date: 2026-07-12

## Scope

Reviewed `AGENTS.md`, the complete active `sdk-performance` proposal/design/specifications/tasks, the Core V1 performance schema and tests, supported `NearWireBuiltins.sendPlatformEvent`, `bufferDiagnostics`, ordinary keep-latest queue behavior, and the existing SDK lifecycle/resource patterns. This review is intentionally lightweight and report-only; no production, test, specification, task, or other evidence artifact was modified.

## Findings

### 1. P1 / High — `droppedEventCount` includes a counter that does not represent dropped events

**Confidence: 10/10**

The design defines `transport.droppedEventCount` as a saturated sum including `transportAdmissionRejected`. In the current SDK, transport admission rejection deliberately leaves the event in the ordinary queue for a later attempt; existing tests explicitly prove rejected keep-latest events remain buffered. Repeated rejection can also increment the counter multiple times for the same retained event. Reporting those attempts as dropped events therefore fabricates a loss count and can count one event repeatedly.

The plan also needs an explicit decision for coalesced predecessors: `bufferDiagnostics.statistics.coalesced` represents events actually removed by keep-latest replacement, but the proposed sum omits it while including non-removing admission rejection.

**Required resolution:** define `droppedEventCount` only from counters that represent terminal removal, and state whether deliberate coalescing is included or excluded. At minimum exclude `transportAdmissionRejected`. Add projection tests where one event is rejected repeatedly but remains buffered, and separate tests for overflow, expiration, routing removal, explicit clear, and coalescing, including saturated addition.

### 2. P2 / Medium — Startup failures have no total lifecycle-state outcome

**Confidence: 10/10**

The plan says setup failure, unsupported macOS start, and a second monitor lease conflict throw typed errors after/no setup, but it does not say whether `currentState` remains Stopped, publishes Failed with that error, or restores a prior Failed state. This makes the state stream and `start()` error disagree under normal branches and leaves restart semantics underspecified. The post-start submission failure and explicit-stop paths are defined more precisely, but stop-versus-failure winner order is only mentioned as a test topic rather than a normative rule.

**Required resolution:** add a total transition table for `start()` from Stopped, Running, and Failed covering success, unsupported platform, lease conflict, partial collector failure, and cancellation; also define the exact winner when stop and post-start failure race. Tests should assert both the thrown result and complete state-stream sequence for each branch, including stale-run suppression after restart.

### 3. P2 / Medium — CPU baseline recovery after a failed reading is undefined

**Confidence: 9/10**

CPU percent is specified as a cumulative process CPU-time delta divided by monotonic elapsed time, while an individual read failure should make only that field temporarily unavailable. The plan does not define what happens to the CPU baseline on failure. Keeping the old CPU baseline while dividing the next successful delta by only the latest snapshot interval overstates CPU; replacing the baseline without a valid reading is impossible. Correct recovery generally requires either a CPU-specific timestamp/baseline spanning the full successful delta or one successful reading that re-baselines while remaining unavailable until the following turn.

Counter regression, timeval conversion overflow, non-positive monotonic delta, and a recovered CPU delta that becomes non-finite also lack an explicit outcome.

**Required resolution:** specify one CPU-baseline state machine and its unavailable/recovery behavior independently of the snapshot header interval. Add table-driven deterministic tests for first sample, real zero, multi-core values above 100, read failure followed by recovery, counter regression, zero/backward elapsed time, and arithmetic overflow/non-finite results.

### 4. P2 / Medium — Estimated-FPS calculation is not defined precisely enough to implement or test consistently

**Confidence: 9/10**

The design says estimated FPS is observed callback cadence over a monotonic display interval and only specifies that zero callbacks is unavailable. It does not define whether the formula is callback count divided by sample elapsed time or `(callbackCount - 1)` divided by first-to-last callback time, nor what happens with exactly one callback, equal/regressing timestamps, a callback on an interval boundary, or a non-positive/invalid maximum frame rate. These choices produce materially different values and off-by-one behavior.

**Required resolution:** state the exact callback/timestamp ownership rule, minimum observation count, formula, boundary inclusion, and invalid-timestamp behavior. Deterministic tests should cover zero, one, and multiple callbacks; 60/120 Hz examples; delayed sampling; equal/backward timestamps; reset between intervals; and maximum-FPS availability independently from estimated FPS.

### 5. P2 / Medium — Disabled versus permanently unsupported precedence is contradictory

**Confidence: 9/10**

The plan requires disabling a group to emit `disabled` for every field in that group, while also requiring stable `unsupported` records in every snapshot for GPU utilization, watts, Celsius temperature, byte rates, and downlink queue depth. It does not assign those unsupported fields to groups or define which reason wins when the containing device/transport group is disabled. Consequently two conforming implementations can emit different unavailable lists for the same configuration.

The same deterministic contract should state whether a present value may coexist with an unavailable record for its key and how duplicate reasons for one key are resolved before sorting.

**Required resolution:** publish the closed metric-key inventory, group ownership, and one reason-precedence table. Require exactly one unavailable record for each absent stable field and no unavailable record for a present field. Add exhaustive all-groups-on/off and individual-read-failure tests that assert exact sorted keys and reasons, not only uniqueness.

## Coverage Assessment

The planned lifecycle/resource, keep-latest, conversion, platform smoke, benchmark, packaging, and consumer tests are proportionate once the five contracts above are made normative. In particular, the existing task list already calls for stop/failure, stale-run, noncooperative dependency, queue coalescing, unavailable, CPU/FPS, and exact-resource tests; those tests need the clarified expected outcomes rather than additional feature scope.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

## Verdict

**Actionable finding count: 5 — one High and four Medium. Pre-implementation correctness/testing approval is withheld pending resolution and a fresh lightweight review.**
