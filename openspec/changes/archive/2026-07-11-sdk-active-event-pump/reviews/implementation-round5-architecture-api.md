# Post-Implementation Architecture and API Review — Round 5

## Scope

Fresh review of the complete current implementation, tests, OpenSpec artifacts, documentation, and evidence, with specific re-verification of both Round 4 architecture findings. Earlier reports were used only to identify the intended remediation areas; conclusions below were re-derived from the current tree and fresh validation.

## Findings

No unresolved actionable architecture or API finding remains.

## Round 4 Remediation Verification

### Wake assignment and the initial snapshot now form one gate outcome

- `registerOutboundWorkWake` performs the exact tokenized callback assignment and computes the initial scheduling result inside one `SDKActiveOperationGate.withOpenClaim` body (`SDK/Sources/NearWire/NearWire.swift:446-476`). A closed gate therefore returns `installed: false` with `terminalFirst`; an open claim completes both assignment and snapshot before terminal close can acquire the gate.
- `BoundedEventQueue.previewActiveSchedule` plans on a value copy and reports due work without changing the live queue or its statistics (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:579-600`). Due work is represented as a level-triggered `dueWorkRemains` result rather than being expired during registration.
- The permanent core latches that due-work result and schedules the ordinary bounded owner refresh (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:592-607`). Ordinary scheduling and drain paths authorize every expiration separately through the named expiration hook and a fresh gate claim (`SDK/Sources/NearWire/NearWire.swift:484-507,569-581`). Terminal can therefore still win between distinct expirations without creating a third wake-installation result.
- The focused queue tests prove the preview is nonmutating and the live registration test proves that two due expirations are later serviced through separate claims, leaving the losing expiration intact for a later open gate (`Core/Tests/NearWireFlowControlTests/BoundedEventQueueTests.swift:126-146`; `SDK/Tests/NearWireTests/NearWireBufferTests.swift:114-179`).

### Named live-operation seams replace global claim-number coupling

- `SDKActiveLiveOperationHooks` now declares operation-specific internal seams for expiration, route drop, candidate claim, Event-mailbox admission, Event-mailbox progress observation, mailbox completion, observer cancellation, and terminal close (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:77-135`). The immutable `SDKActiveLiveOperations` value binds them with the exact owner, channel, clock, and gate before active mutation (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:137-224`; `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:521-529`).
- The concrete queue drain invokes the route, candidate, Event-mailbox admission, and progress seams at their actual production boundaries without bypassing encoding, mailbox admission, or the shared gate (`SDK/Sources/NearWire/NearWire.swift:569-603,664-717`). Mailbox completion, observer cancellation, and terminal close invoke their named seams immediately before their corresponding core transitions (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:715-724,743-765,1842-1849`).
- Tests address the second expiration through the named expiration seam, and address route, candidate, Event-mailbox admission/progress, completion, observer cancellation, and terminal close through their own named seams (`SDK/Tests/NearWireTests/NearWireBufferTests.swift:148-174,292-339,570-613,723-795`; `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1598-1662`). The remaining target-entry counter selects the second expiration occurrence, not the second global operation-gate claim. No test installs a generic `SDKActiveOperationGateHooks.beforeClaim` ordinal barrier.

## Architecture and API Boundary Verification

- Live owner/channel operations remain captured in one immutable internal value; the permanent core does not accept substitutable route, validation, clock, mailbox, or gate behavior through the test seams.
- The initial-policy path preserves Control priority after a live owner refresh while retaining due-work hints for the first active drain (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:641-677`).
- The active-pump implementation adds no supported SDK declaration. `Package.swift` and `NearWire.podspec` remain unchanged, and the active-pump session files expose no `public` or `open` declarations.
- The ownership/resource audit, requirement mapping, focused evidence, API inventory, and English active-pump documentation now describe the implemented atomic snapshot and named-seam architecture consistently.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round5-architecture-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round5-architecture-swiftpm-cache swift test --filter 'SDKSessionAdmissionTests|NearWireBufferTests'`: PASS — 97 tests, 0 failures (`SDKSessionAdmissionTests`: 71; `NearWireBufferTests`: 26). The first sandboxed attempt could not compile the package manifest because nested `sandbox-exec` is unavailable; the same command passed outside that environment restriction.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `./Scripts/verify-boundaries.sh`: PASS — module imports, Core SPI visibility, secure transport construction, SwiftPM/CocoaPods boundaries, and the distribution manifest contract all passed.
- `git diff --check`: PASS with no output before this report was added.
- `git diff -- Package.swift NearWire.podspec`: PASS with no output.
- Internal active-pump declaration inventory: PASS with no `public` or `open` declaration in the reviewed SDK session files.

## Unresolved Count

**0 unresolved findings. Architecture/API closure is granted.**
