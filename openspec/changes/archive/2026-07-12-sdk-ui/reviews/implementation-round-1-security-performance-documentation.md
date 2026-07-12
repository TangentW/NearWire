# SDK UI Implementation Security, Performance, and Documentation Review — Round 1

## Result

**Unresolved actionable finding count: 5** — one High and four Medium.

The implementation preserves several important boundaries: pairing input is scalar-safe and capped, production source contains no logging/persistence/pasteboard/analytics/lifecycle API, unexpected errors are sanitized, one coordinator serializes Connect/Disconnect, the fail-closed Disconnect tail is code-free, public production source compiles under the recorded minimum-platform/strict-concurrency gates, and fixed-English/non-live-region limitations are documented. The findings below block completion because the subscriber/observation lifetime contract is not implemented, accessibility and iOS evidence are incomplete, the public-delta gate is not exact, and pairing/evidence documentation overstates current guarantees.

## Findings

### 1. High — Observation termination is not self-cleaning and model release creates an unbounded hidden cleanup-Task path

**Evidence**

- `subscribe(controller:)` stores each continuation in the coordinator, but installs no `onTermination` handler. The only direct removal API is `unsubscribe(controller:token:)` (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:107-138`). A cancelled iterator therefore remains registered while the coordinator is idle unless some later phase yield opportunistically reports `.terminated` (`NearWireUIOperationCoordinator.swift:267-285`).
- `Entry` stores neither the exact controller nor another unsubscribe key independent of that controller (`NearWireUIOperationCoordinator.swift:95-103`). `unsubscribe` must recompute `ObjectIdentifier(controller)`. If the caller loses the controller before explicit unsubscribe, the stale idle entry cannot be addressed and no strong entry owner prevents object-identifier reuse.
- The model works around release without `stop()` by cancelling its observation handles and launching a new `Task { @MainActor ... }` from `deinit` to cancel Connect and unsubscribe (`SDK/Sources/NearWireUI/NearWireUIModel.swift:40-58`). That Task is not either allowed observation or coordinator action Task; it retains controller/coordinator/tokens until scheduled. Releasing many models before the main actor drains can enqueue one cleanup Task and leave one continuation per model.
- Both observations are created with unstructured `Task {}` handles (`NearWireUIModel.swift:64-84`). `stop()` cancels and drops those handles without completion acknowledgement (`NearWireUIModel.swift:87-113`). Rapid synchronous stop/start can therefore leave multiple cancelled predecessor Tasks and status streams alive until executor turns process them, despite the requirement of one structured observation of each kind per live model.
- Current tests prove explicit model `stop()` and eventual deinit cleanup, but do not cancel a phase consumer without calling `unsubscribe`, hold a noncooperative observation across rapid stop/start, count live observation Tasks, or release a burst of models before cleanup. The coordinator controller test explicitly unsubscribes before dropping the controller (`SDK/Tests/NearWireUITests/NearWireUIOperationCoordinatorTests.swift:109-123`), so it does not prove stale-entry or `ObjectIdentifier` reuse safety.

**Impact**

Normal `onDisappear` usually takes the explicit path, but the supported model-release and stream-termination guarantees are broader. Cancellation or release outside that exact ordering can retain idle coordinator entries, continuations, controller references, status-stream subscriptions, and queued cleanup Tasks. Repeated churn can exceed the stated constant observation/resource bounds, and a stale object-identifier key can collide with a later controller.

**Required remediation**

Make phase termination remove its exact registration without depending on a later phase yield, and make controller/key lifetime safe until removal. Use a design that does not create one untracked cleanup Task per model release. Define observation ownership in terms of live Tasks rather than stored handles, or add exact cancellation completion before successors start. Add adversarial tests for direct iterator cancellation, idle termination with no later phase, release without explicit unsubscribe, controller release/reuse, a burst of model releases, and rapid held status/phase stop-start; assert subscriber, entry, controller, and live-Task counts return to their exact bounds.

### 2. Medium — Reconnect-attempt text is omitted from the combined accessibility semantics

**Evidence**

- Reconnect count exists only as visual `secondaryText` such as `Attempt 3` (`SDK/Sources/NearWireUI/NearWireUIPresentation.swift:74-82`). The reconnect accessibility hint is the generic restoration sentence and contains no attempt number.
- The status view combines children but then explicitly replaces the element label with `presentation.label` and the hint with `accessibilityHint(for:)` (`SDK/Sources/NearWireUI/NearWireConnectionStatusView.swift:54-61`). That method appends only an error; it never appends `secondaryText`. The explicit label/hint therefore omits the retry count that was visible in the combined children.
- The test named `testRetryAndSuspensionRemainVisibleInTextAndAccessibilityHint` asserts retry only in `secondaryText`; it checks the hint only for `paused` (`SDK/Tests/NearWireUITests/NearWireUIPresentationTests.swift:30-46`). The structure audit merely checks that some accessibility label/hint token exists anywhere in source (`Scripts/check-sdk-ui-structure.rb:41-43`).

**Impact**

VoiceOver users cannot obtain the current reconnect attempt even though sighted users can. The implementation and evidence do not satisfy the closed retry/accessibility presentation requirement, while the roadmap and SDK UI documentation claim complete accessible state.

**Required remediation**

Create one closed final accessibility label/hint value that includes retry, suspension, progress, and safe error text, bind the view to it, and test exact output for every state and retry/suspension/error combination. Strengthen the source audit so the required presentation values—not merely any modifier occurrence—must be bound to the status element.

### 3. Medium — The Dynamic Type rendering test is macOS-only and does not render the connection panel

**Evidence**

- `NearWireUIViewSmokeTests` unconditionally reads `ImageRenderer.nsImage` (`SDK/Tests/NearWireUITests/NearWireUIViewSmokeTests.swift:9-19`). The iOS SwiftUI interface exposes `uiImage`; `nsImage` exists only in the macOS SwiftUI interface. The test target therefore cannot compile this file for the required iOS test platform.
- The test evaluates `NearWireConnectionView.body` but applies accessibility Dynamic Type and `ImageRenderer` only to `NearWireConnectionStatusView`. Pairing input, action controls, reset, and inline error layout are not rendered at a large accessibility size.
- Focused evidence records production iOS/macOS target builds but says the simulator test stage was not reached (`openspec/changes/sdk-ui/evidence/focused-implementation-validation.md:46-61`). Task 3.5 is nevertheless marked complete.

**Impact**

The current macOS test passes while the corresponding iOS test source is invalid and the larger connection panel has no large-content-size rendering evidence. This leaves both a minimum-platform test break and an accessibility layout gap hidden by the partial package run.

**Required remediation**

Use platform-conditional `uiImage`/`nsImage` assertions and render both public views, including representative error/reset and progress shapes, at a large accessibility Dynamic Type size. Run the actual iOS Simulator test target and record the result before marking the evidence task complete.

### 4. Medium — Packaging checks do not enforce the claimed exact public UI declaration delta

**Evidence**

- `check-sdk-ui-structure.rb` counts two public structs, two `public init` lines, and two public `body` lines, but it does not reject an additional public function, property, protocol, enum, extension member, conformance, nested type, or typealias (`Scripts/check-sdk-ui-structure.rb:14-28`).
- The Swift API digester step verifies that the CocoaPods UI aggregate contains all SDK USRs and that both expected view names appear. It does not compute and compare the CocoaPods aggregate-minus-SDK declaration set with a normalized SwiftPM NearWireUI inventory (`Scripts/verify-package.sh:555-601`). The final source regex has the same extra-member blind spot.
- Current source happens to expose only the intended surface, but the evidence is described as aggregate/delta/forbidden public API validation and task 3.5 is marked complete.

**Impact**

An accidental additional supported API can pass every new UI packaging gate, especially in the single CocoaPods module where module-name differences already require normalization. The boundary scripts therefore do not protect the documented two-view compatibility contract.

**Required remediation**

Extract supported declarations from both API-digester documents, normalize module-dependent identifiers/signatures, and compare the exact CocoaPods aggregate delta against the exact SwiftPM NearWireUI surface. Add mutation/self-tests proving that extra public top-level and member declarations fail. Keep the existing SDK-only and internal-type negative consumers.

### 5. Medium — Pairing-retention documentation and completion evidence overstate the current implementation

**Evidence**

- The implementation correctly clears model input at success, Cancel/Disconnect, and stop, while the Connect Task captures one bounded `code` until it returns (`NearWireUIModel.swift:171-191`; `NearWireUIOperationCoordinator.swift:140-170`).
- `Documentation/SDK-UI.md:51-55` says input clears after disappearance or model teardown but does not disclose that one cancelled in-flight Connect argument may remain until exact SDK completion, nor that secure String zeroization is not promised. The specification explicitly requires that separate lifetime disclosure (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:31-33`).
- The same document says NearWireUI “never creates or owns an SDK facade” (`Documentation/SDK-UI.md:3`), while the public view/model necessarily retain the injected instance. The intended guarantee is no construction, replacement, or lifecycle-policy ownership—not absence of retention.
- Tasks 3.4 and 4.1 are marked complete even though current tests contain no pairing-copy lifetime probe, direct terminated-subscriber cleanup test, weak origin-completion release probe, or adversarial object-identifier reuse test (`openspec/changes/sdk-ui/tasks.md:18,23`). Focused evidence accurately reports the current 26-test pass, but full package/pod/simulator evidence and requirement-to-evidence/resource audits remain incomplete under tasks 5.2 and 5.3.

**Impact**

Integrators can infer a stronger pairing erasure and facade-lifetime guarantee than the SDK provides, and checked tasks make missing retention evidence look complete. This is particularly risky for later reviewers relying on the evidence directory rather than re-reading implementation details.

**Required remediation**

Document model clearing separately from the capped in-flight argument lifetime and explicitly state that secure zeroization is not promised. Replace “never owns” with precise construction and lifecycle-policy language. Add the missing lifetime probes, correct completed checkboxes until evidence exists, rerun all current gates, and record fresh requirement-to-evidence, resource-retention, public inventory, and spec-to-evidence audits.

## Verified Boundaries

- `NearWireUIInputLimiter` correctly stops at a Unicode-scalar boundary and retains at most 64 UTF-8 bytes. The production module contains no logging or diagnostic interpolation of pairing input.
- Unknown controller errors map to the fixed generic sentence; only `NearWireError.message` reaches action/status presentation. No underlying error description is interpolated.
- The action coordinator admits one Connect and at most one preempting Disconnect per exact key. Repeated Disconnect joins the existing Task, and the nonreturning Disconnect closure is code-free and model-free.
- Production NearWireUI source imports SwiftUI and the supported facade only. No forbidden persistence, Keychain, file, pasteboard, camera, analytics, notification, reachability, application-lifecycle, background-execution, UIKit/AppKit wrapper, Combine, SPI, or detached-Task API was found.
- UI strings are visibly fixed English; documentation discloses that they are not localized and that no automatic live-region announcement is promised. No resource bundle, font, asset, entitlement, privacy declaration, or runtime dependency was added.
- Root package and pod mappings remain iOS 16 / macOS 13, Swift 5 language mode, with complete concurrency and warnings-as-errors gates. Current production target and consumer checks recorded in focused evidence reached both minimum-platform compiles before simulator service failure.

## Validation Performed

- Strict current NearWireUI suite: PASS — 26 tests, 0 failures, complete concurrency, warnings as errors.
- `ruby Scripts/check-sdk-ui-structure.rb`: PASS, while retaining the coverage limitations in Findings 2 and 4.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS.
- `git diff --check`: PASS.
- Direct SDK interface inspection confirms `ImageRenderer.nsImage` is macOS-only and `ImageRenderer.uiImage` is the iOS property; an iOS XCTest typecheck could not be completed directly outside an Xcode test destination because the standalone iPhoneOS invocation could not load the XCTest module.

## Final Verdict

**Not ready for completion.** Repair the termination/observation ownership path first, then close accessibility, iOS rendering, public-delta validation, pairing disclosure, and evidence-audit gaps. A fresh implementation review round is required after remediation.
