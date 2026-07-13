# Architecture and API Implementation Review - Round 9

## ARCH-R9-001 - P1 High: the traversal coordinator drops Store-generation delivery validity

**Confidence:** 10/10

The round-8 shared generation-validity cell correctly protects operations retained by
`ViewerEventExplorerController`, but the primary timeline traversal bypasses that protection.
`ViewerExplorerStoreDriver` erases every `ViewerStoreExplorerOperationToken` by exposing
`endTraversal`, `replaceQuery`, `loadTailPage`, and `loadTailGaps` as `Void`-returning closures
(`Viewer/NearWireViewer/Application/ViewerEventExplorerCoordinator.swift:45-82`). Their callbacks
are admitted on the MainActor using only `ViewerExplorerPresentationToken`, which is a model/filter
generation rather than the immutable Store coordinator generation (`289-299`, `415-447`).

This permits a deterministic cross-generation retarget. An old-generation `endTraversal` can
finish and have its client callback delayed after the gateway has retired the operation. Store
replacement then invalidates that generation and publishes the successor. When the callback finally
runs, its presentation token is still current, so `handleRelease` starts `replaceQuery` through the
dynamically routed driver and silently attaches the predecessor traversal chain to the new Store
generation. The same missing identity lets old query, tail-page, or gap callbacks reach presentation
until a later asynchronous status refresh changes the model generation. This violates both the
exact-generation completion requirement and the Store contract that late work must not attach to a
replacement implicitly.

Do not use the presentation token as a substitute for Store identity. Preserve the immutable gateway
operation token, or an equivalent token-bound result envelope, for every traversal stage. Before a
callback applies state or launches the next stage, require that exact Store-generation validity to
remain live. An invalid predecessor must retire its exact work identity without updating presentation
or issuing successor-generation work. Store availability may then initiate a fresh traversal under a
new presentation and Store generation.

Add blocked-delivery replacement regressions for release, query replacement, tail page, and gaps.
For each stage, claim or produce the predecessor result, install a replacement, release delivery, and
prove that no old result is applied and no new-generation request is issued implicitly. Then prove an
explicit fresh traversal succeeds and all gateway, coordinator, traversal, and lease counts reach
zero.

## ARCH-R9-002 - P1 High: the controller revokes authoritative committed-export success

**Confidence:** 10/10

The export gateway intentionally preserves a successful candidate after atomic destination
replacement even if generic cancellation or Store replacement wins before result delivery.
`executeExport` opts into `successfulCandidateIsAuthoritative`, and `finish` preserves that success
for both `.cancelled` and `.storeReplaced` operation states
(`Viewer/NearWireViewer/Store/ViewerStoreExplorerGateway.swift:792-810,1014-1034`). The controller
places export execution into its ordinary revocable operation path instead
(`Viewer/NearWireViewer/Application/ViewerEventExplorerController.swift:1114-1139`).

After the file commits, `cancelExport` removes and cancels `.exportExecution` and immediately
publishes `.cancelled` (`1143-1149`). A later authoritative gateway success is then rejected either by
the delivery gate or by the missing controller operation identity. Store replacement has the same
effect through `finish`, which requires the now-invalidated shared Store token (`1884-1892`). The
destination can therefore contain the completed export while Viewer reports cancellation or remains
stuck in `.exporting`. This regresses the round-6 gateway guarantee and the design contract that a
committed success remains authoritative across cancellation or coordinator replacement
(`openspec/changes/viewer-event-explorer-control/design.md:331-341`).

Export execution needs an explicit commit-aware controller state machine rather than the generic
late-result rule. A user cancellation should request exact gateway cancellation but retain the
result-delivery identity until the gateway classifies the outcome. Pre-commit cancellation remains
cancelled; a reported committed success must retire that identity and publish completed while the
controller is live, even when cancellation or Store replacement raced with delivery. Runtime sealing
must still join the callback and clear presentation without repopulating the sealed controller. The
capability specification should also state this narrow content-free committed-receipt exception so it
does not conflict with the general predecessor-result discard rule.

Add controller-level commit-boundary tests for both user cancellation and Store replacement. Block
delivery after atomic replacement, apply the race, release delivery, and prove completed state, one
callback, the replaced JSON destination, and zero gateway/controller work. Preserve the existing
old-generation catalog rejection and pre-commit export cancellation coverage.

## Reviewed remediation and validation

The owner-level renderer and composer delivery pumps are structurally bounded to one processing plus
one replaceable pending value, schedule one drain chain, release displaced values outside the lock,
and join their tracked drains during cleanup. The native export-destination selection seam has one
controller-owned gate, tracker, cancellation handle, and weak controller capture; delayed AppKit
responses cannot retain or repopulate a sealed explorer. The direct controller generation-validity
fix correctly protects catalog and other token-retaining content operations, but it does not cover
the traversal-driver erasure or the committed-export exception above.

Core/SDK/Viewer boundaries remain intact, and no new public SDK API or third-party runtime dependency
was introduced. The reviewed source remains compatible with Swift 5 language mode and macOS 13.
`git diff --check` and strict OpenSpec validation pass. Configured signing and embedded-entitlement
verification remains deferred to Goal-level `release-hardening` and is not a finding.

**Unresolved findings: 2**
