# Implementation Architecture and API Review — Round 1

## Scope

Reviewed the uncommitted `sdk-ui` production sources, tests, package and CocoaPods mappings, validation scripts, documentation, proposal, design, delta specifications, tasks, and recorded focused evidence. The review traced the exact two-type public surface, injected-instance identity, main-actor isolation, operation and subscriber bounds, teardown, and SwiftPM/CocoaPods API parity. This was report-only; no production, test, specification, task, or documentation source was modified.

## Findings

### P1 — High: A repeated activation can discard the accepted Connect token and suppress its result

**Confidence: 0.98**

`NearWireUIConnectionModel.connect()` advances `actionGeneration` and assigns the optional result of `coordinator.connect(...)` directly to `activeOperationToken` (`SDK/Sources/NearWireUI/NearWireUIModel.swift:171-183`). The coordinator synchronously accepts the first request, records token A, and yields `.connecting`, but the model does not update its own `operationPhase` until its asynchronous phase-stream task runs (`NearWireUIModel.swift:69-74,199-202`; `NearWireUIOperationCoordinator.swift:145-171`). During that handoff window, a second activation still passes the model's `.idle` guard. The coordinator correctly rejects it by returning `nil` (`NearWireUIOperationCoordinator.swift:146-149`), but the model then increments the generation again and overwrites token A with `nil`.

The controller still receives only one call, so coordinator deduplication appears correct, but token A's eventual origin completion can no longer pass the model's exact generation/token guard (`NearWireUIModel.swift:204-221`). A successful connection therefore may leave the pairing code uncleared, and a failed connection may suppress its inline action error. This violates the exact origin-completion and current action-generation contract (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:49,53-56,102-121`) even though the underlying SDK operation remains serialized.

**Required remediation:** make model admission synchronous and monotonic. At minimum, reject another local Connect while `activeOperationToken` is non-`nil`, and only advance the action generation or replace the token after coordinator admission succeeds. Prefer returning an explicit accepted operation value and synchronously reflecting the accepted phase in the model so presentation and ownership change in the same main-actor turn. Add a deterministic test that invokes the primary action twice before yielding, then verifies one controller call and that token A's success and failure outcomes still update the initiating model.

### P2 — Medium: Phase-stream termination does not remove its exact coordinator subscriber

**Confidence: 0.99**

`subscribe(controller:)` stores the continuation under an exact token but installs no `continuation.onTermination` handler (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:107-127`). Removal currently occurs only through an explicit `unsubscribe` call or opportunistically when a later phase yield reports `.terminated` (`NearWireUIOperationCoordinator.swift:129-138,267-279`). If the stream consumer terminates without the explicit model teardown path, the exact continuation remains in the entry until another phase transition happens; an idle entry cannot then be pruned (`NearWireUIOperationCoordinator.swift:281-286`).

The current model normally calls `unsubscribe`, so this does not make ordinary `onDisappear` leak. It nevertheless contradicts the coordinator's independently cancellable registration contract and its explicit requirement that termination remove only the exact continuation (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:49`; `openspec/changes/sdk-ui/design.md:60-70,86-90`). It also makes the internal abstraction's resource bound depend on every caller remembering a second cleanup operation.

**Required remediation:** install an exact-token termination callback that re-enters the main-actor coordinator weakly, removes only that registration, and runs the same idle-prune rule. Keep explicit `unsubscribe` idempotent. Add a test that cancels or drops a stream consumer without manually unsubscribing and proves the subscriber and idle entry are removed while another live registration remains untouched.

### P2 — Medium: The CocoaPods UI parity gate does not compare the promised aggregate API or exact UI delta

**Confidence: 0.97**

The distribution requirement calls for the CocoaPods UI-installed aggregate to match the combined supported SwiftPM `NearWire` plus `NearWireUI` inventories, with an exact UI declaration delta (`openspec/changes/sdk-ui/specs/sdk-public-boundary/spec.md:3-11`). The new gate only proves that the SDK inventory is a subset of the CocoaPods aggregate, searches the two view names as text in the API JSON, and scans source text for exactly two `public struct`, `public init`, and `public var body` spellings (`Scripts/verify-package.sh:572-601`; `Scripts/check-sdk-ui-structure.rb:14-28`). It does not reject an extra public enum, class, function, property, extension member, conformance, or a changed supported signature, and it never semantically compares the SwiftPM UI inventory with the aggregate-minus-SDK delta.

The current source inspection shows only the intended two public view structs, so this is a validation architecture defect rather than evidence of an extra API today. However, task 3.5 is marked complete and the focused evidence claims aggregate/delta parity from this gate (`openspec/changes/sdk-ui/tasks.md:19`; `openspec/changes/sdk-ui/evidence/focused-implementation-validation.md:48-57`). The gate cannot support that claim or protect the exact public API over subsequent edits.

**Required remediation:** normalize the API digester trees into module-independent declaration/signature records, then assert `CocoaPodsAggregate == SwiftPMSDK + SwiftPMUI` and `CocoaPodsAggregate - SwiftPMSDK == expectedUIDelta`. Include conformances, members, access levels, parameter/result types, and reject every unexpected supported declaration. Keep the SDK-only and forbidden-internal compile fixtures as complementary negative checks.

## Confirmed Architecture and API Properties

- The current supported UI source exposes only `NearWireConnectionView` and `NearWireConnectionStatusView`, with the specified injected/value-driven initializers; no implementation type is currently public or SPI.
- The public wrapper keys the state-owning child with `ObjectIdentifier(nearWire)`, preserving exact injected-instance replacement semantics without creating another SDK facade.
- The coordinator is main-actor isolated, keyed by exact controller identity, and bounds active work to one Connect plus at most one preempting Disconnect. Both asymmetric completion orders keep the entry Disconnecting until both exact operations acknowledge completion.
- Model teardown explicitly invalidates generations, unregisters its exact phase subscription, cancels status/phase observation, and does not disconnect an already active host-owned session.
- SwiftPM keeps NearWireUI optional and separate; CocoaPods keeps SDK as the default subspec and adds the same sources only through `NearWire/UI`. No third-party runtime dependency or additional package manifest/podspec was introduced.

## Validation Performed

- Strict focused test command with complete concurrency and warnings as errors: passed, 26 tests, 0 failures.
- `ruby Scripts/check-sdk-ui-structure.rb`: passed.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.

Passing validations do not cover the three findings above: the model suite does not perform two Connect activations before a phase-consumer turn, coordinator tests explicitly unsubscribe every registration, and the API script performs subset/name/source-text checks rather than semantic aggregate-delta equality.

## Verdict

**Changes required. Unresolved actionable findings: 3 (1 high, 2 medium). Architecture/API approval is withheld until the accepted Connect ownership race, exact termination cleanup, and semantic distribution parity gate are fixed and re-reviewed.**
