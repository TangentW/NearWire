# Post-Implementation Security, Performance, and Documentation Review — Round 1

## Findings

### HIGH — Cancellation authority is not transferred atomically and a cancelled attempt can start a live channel

Evidence:

- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:142-189`
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:176-201`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:756-798`
- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:29-31`

After discovery succeeds, the admission actor remains in `discovering` while it constructs a core and channel and then suspends at `await transportCore.bind(channel:)`. Cancellation handled during that suspension records `cancelled` only on the admission actor and finds no discovery operation to cancel. When `bind` returns, `execute()` does not recheck the cancellation outcome; it overwrites the state with `transferred` and starts the core.

There is a second loss window after `transferred` is recorded but before `SDKSessionTransportCore.run()` installs `attemptToken`. A forwarded `cancelAttempt` that reaches the core first observes a nil token and is discarded, after which `run()` may start the deadline and secure channel. The current cancellation test waits for the driver to start, after both vulnerable windows.

Remediation:

- Arm the core with the immutable attempt token and transfer terminal/result authority before the first post-discovery suspension and before channel construction.
- Make a cancellation received by an armed but not-yet-bound/not-yet-run core persist and prevent subsequent channel startup.
- Never overwrite a cancelled admission state after an actor hop.
- Add deterministic barriers covering cancellation before/during bind and after transfer but before run registration. Assert one `cancelled` result, no channel revival, no deadline leak, and at-most-once channel cancellation.

### HIGH — Pull-token reuse lets a stale cancellation callback cancel a later policy pull

Evidence:

- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:261-305`
- `SDK/Sources/NearWire/Session/SDKSessionAdmissionModels.swift:324-368`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:405-474`
- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:119-123`

`registerPolicyPull` captures the current `nextPullToken` in the gate callback but increments the counter only when an empty FIFO installs a waiter. Immediate FIFO delivery, terminal return, and `pullAlreadyPending` close their gates without retiring that token. Cancellation can already have extracted and scheduled the callback before `close()` wins. If a later empty pull reuses the same token, the stale callback matches the new waiter and cancels it, violating the requirement that losing tokens be ignored.

Remediation:

- Allocate a unique token for every successfully claimed gate before installing its callback, including immediate and rejected core outcomes; a private reference-identity token avoids ABA and counter-exhaustion ambiguity.
- Alternatively, advance the counter for every claimed gate and define the exhaustion outcome explicitly.
- Add deterministic tests that delay cancellation callbacks from immediate-FIFO and `pullAlreadyPending` calls, install a later waiter, then release the stale callbacks and prove the later waiter remains pending.

### HIGH — The ingress drain can monopolize the core actor and temporarily exceeds the documented retained budget

Evidence:

- `SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:75-115`
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:209-225`
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:346-395`
- `Documentation/SDK-Session-Admission.md:40-58`
- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:70-74`

`drainIngress()` synchronously loops until `takeBatch()` observes an empty queue and contains no actor yield or bounded drain quantum. A peer that continuously replenishes small receive fragments can keep this actor job running while complete-frame work counters remain unchanged. Secure-admission deadlines, external cancellation, attachment, and pull operations then cannot execute on the same actor, weakening the timeout and cancellation guarantees intended to bound a callback storm.

`takeBatch()` also resets pending count and byte accounting before the returned batch is processed. One full batch can therefore be retained on the drain task while another full batch accumulates in `pending`, making total callback-edge retention approximately twice the documented 64-event/256-KiB default and 256-event/1-MiB hard limit.

Remediation:

- Drain at most a fixed, small quantum per actor turn and reschedule exactly one continuation drain when work remains, so deadline, cancellation, terminal, and attachment jobs can run.
- Account for the in-flight batch until processing completes, or explicitly define and validate a combined pending-plus-in-flight budget whose documented values match actual peak retention.
- Add a deterministic continuous-producer test proving timeout and cancellation execute before frame completion without exceeding the combined event/byte bound.

### MEDIUM — Unsolicited browser cancellation is reported as expected caller cancellation

Evidence:

- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:257-271`
- `SDK/Sources/NearWire/Discovery/ViewerDiscoveryCoordinator.swift:107-108`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:894-908`
- `openspec/changes/sdk-session-admission/design.md:179-186`

`map(discoveryError:)` maps every `ViewerDiscoveryError.cancelled` to the admission `cancelled` code. The discovery coordinator uses that same error when the browser reports an unsolicited cancellation. The approved error table reserves `cancelled` for explicit/task cancellation and maps other discovery failures to `discoveryFailed`; treating an external browser termination as expected cancellation hides an operational failure and makes terminal classification dependent on an ambiguous lower-layer code.

Remediation:

- Use `discoveryTerminalOverride` and the admission task's cancellation state to classify expected cancellation.
- Map a coordinator `.cancelled` with no local cancellation authority to `discoveryFailed`.
- Add separate tests for explicit cancellation, task cancellation where the inner discovery cancellation wins the race, and unsolicited browser cancellation.

### MEDIUM — Required real-TLS and packaging evidence is not yet present

Evidence:

- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:873-892`
- `openspec/changes/sdk-session-admission/tasks.md:25-34`
- `openspec/changes/sdk-session-admission/evidence/` is absent

The live-dependency test only constructs a production App channel and inspects setup state and limits. It does not start a real TLS connection, exchange hello/acknowledgement bytes, validate `vid` against the decoded Viewer hello, or return an admitted owner through the production transport boundary. Tasks 4.3 through 5.3 correctly remain incomplete, but there is currently no saved real-TLS, SwiftPM/CocoaPods boundary, full-validation, or API-inventory evidence for this implementation.

Remediation:

- Add the planned unrestricted integration test using the real secure Viewer listener and App channel through acknowledgement and deterministic teardown.
- Run the full SwiftPM, CocoaPods, API inventory, structure, strict-concurrency, version, documentation, and strict OpenSpec gates.
- Save exact commands, counts, environment/run identity, expected limitations, and outputs under the active change's `evidence` directory before marking the tasks complete.

## Validation Performed

- `swift test --disable-sandbox --filter SDKSessionAdmissionTests`: 22 passed, 0 failed.
- `ruby Scripts/check-session-admission-structure.rb .`: passed.
- `openspec validate sdk-session-admission --strict`: passed; optional PostHog telemetry flush failed because network access was unavailable and did not affect validation.
- Static review of the complete active OpenSpec artifacts, current uncommitted source/test/documentation/package diff, and retained-state ownership graph.
