# Architecture and API Implementation Review - Round 10

## ARCH-R10-001 - P2 Medium: a synchronously rejected traversal successor is treated as delivery-valid

**Confidence:** 9/10

The round-9 remediation preserves the exact Store token through release, query, page, and gap
stages, and the gateway no longer routes an old chain onto a replacement generation. One
replacement window still violates the presentation half of that contract.

`ViewerStoreExplorerGateway.withGeneration(following:)` rejects a predecessor that is no longer
current by synchronously completing with `.storeReplaced`, but it returns a synthetic token whose
`coordinatorGeneration` is zero
(`Viewer/NearWireViewer/Store/ViewerStoreExplorerGateway.swift:509-524`). Generation-zero tokens
have no validity cell and `ViewerStoreExplorerOperationToken.isDeliveryValid` deliberately treats
them as valid (`32-49`). That behavior is useful for a new direct request made while no Store is
available, but it is wrong for a successor rejected because its predecessor has just retired.

The concrete interleaving is:

1. `handleRelease` or `handleQueryReplacement` reads generation A's predecessor token as valid.
2. Store generation B is installed before the handler submits its query, page, or gap successor.
3. The gateway rejects the successor synchronously and returns the generation-zero token.
4. The synchronous-completion delivery box attaches that token before the queued MainActor task
   runs, so `validToken` accepts it.
5. `handleQueryReplacement`, `handleTailPage`, or `handleTailGaps` applies `.failed(.storeReplaced)`,
   clears progress, and publishes presentation
   (`ViewerEventExplorerCoordinator.swift:495-570`).

No operation is retargeted to B, but a predecessor chain that lost Store ownership still mutates
presentation after retirement. The design requires a retired predecessor to do neither, and the
explicit replacement scenario requires generation A's result to be discarded
(`design.md:127-134`; `specs/viewer-event-explorer-control/spec.md:158-162`). The existing stage
test invalidates a stage token before its completion is handled, while the gateway test validates
only the no-retarget result. Neither covers invalidation between a successful handler check and its
successor submission.

Keep the valid generation-zero token for direct `.unavailable` requests, but return a
delivery-invalid token for a rejected `following:` request. It can share the retired predecessor's
already-invalid validity cell or use a dedicated false validity value. The callback must still
retire the coordinator work identity, but the delivery box must discard it without changing state.
Preserve the current synchronous attachment ordering and gateway lock/reentrancy rules.

Add deterministic regressions for both release-to-query and query-to-page/gap transitions. Pause
the handler after it accepts generation A's result, install B, then allow successor submission.
Prove the synchronous rejection changes no timeline, gap, progress, error, accessibility, or
presentation state, issues no operation on B, retires all work, and permits one explicit fresh
traversal on B.

## Reviewed remediation and validation

The commit-aware export remediation is structurally sound. User cancellation retains the exact
export operation and delivery identity in `cancelling`; the gateway alone classifies the commit
boundary; the controller accepts the exact content-free terminal receipt despite Store invalidation;
and runtime sealing still cancels, clears, and joins without repopulating the sealed controller.
The pre-commit cancellation, post-commit cancellation, and post-commit Store-replacement tests all
pass.

Outside the finding above, traversal successors remain bound to the predecessor generation and
cannot attach to the replacement. The token delivery box safely handles synchronous completion on
the MainActor, operation trackers retire exactly once, and runtime cleanup joins the process Store
gateway through `ViewerStoreRuntime.runtimeEnded` in addition to the presentation receipts. No new
public SDK API, Viewer target in the root package, remote package, shell build phase, or third-party
Core/SDK runtime dependency was introduced. Core's added wire carrier fields remain internal SPI
and do not change encoded wire output.

Fresh validation completed with these results:

- Six focused traversal, export-boundary, and delayed-destination tests passed with zero failures.
- `git diff --check`, strict OpenSpec validation, and recursive strict Swift format lint passed.
- `swift package dump-package` passed and confirms no dependencies, iOS 16, macOS 13, Swift 5,
  and no Viewer target.
- Viewer build settings resolve to macOS 13, Swift 5.0, and complete strict concurrency; source
  `Info.plist` and entitlement plist parsing passed.

Configured signing and validation of entitlements embedded in a signed product remains deferred to
Goal-level `release-hardening` and is not a finding.

**Unresolved findings: 1**
