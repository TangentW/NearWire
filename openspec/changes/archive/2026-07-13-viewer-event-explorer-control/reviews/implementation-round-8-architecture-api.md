# Architecture and API Implementation Review — Round 8

## ARCH-R8-001 — P2 Medium: retired coordinator results can still update presentation after replacement

Confidence: High

The round-7 transition mutex fixes the three-coordinator overwrite: detach, predecessor join, and
successor publication are now serialized, and a callback-installed generation deterministically
wins after an external installation releases transition ownership. However, the remediation retires
an active gateway operation before invoking its completion. `submitIdentified` calls
`prepareCompletion` and `complete` before `completion(result)`, so `install` can observe an empty
completion group, publish a replacement, and return while the predecessor callback is still blocked.
`testExplorerGatewayReplacementRetiresOperationBeforeArbitraryCompletion` now explicitly proves
that ordering.

The presentation boundary does not carry the coordinator generation through that remaining delivery.
`ViewerEventExplorerController.ActiveOperation` stores the gateway token only for cancellation, while
`finish` accepts a result solely by the controller-local operation UUID. A predecessor callback that
already claimed its delivery gate may therefore create its MainActor task after the successor is
published and still apply an old catalog, page, detail, mutation, or export result. The later store
status refresh is asynchronous and cannot prevent the old value from flashing first; for operations
that are not immediately superseded, the old presentation can remain longer. This contradicts the
requirements that late coordinator work cannot publish and that late operation/presentation
generations cannot update the MainActor.

Do not restore callback ownership to the gateway completion group, because that recreates the
round-6 reentrant-installation deadlock. Instead, split resource retirement from result-delivery
validity: associate every controller delivery gate with the immutable coordinator generation and
atomically invalidate the retired generation before successor publication. A delivery that was
already claimed must remain tracked until its MainActor task runs, but that task must discard the
result when the generation has been invalidated. Preserve the current serialized replacement owner
for detach/join/publish ordering.

Add a controller-level regression that blocks an old generation immediately after delivery claim,
installs a replacement, then releases the MainActor delivery. Prove that no old catalog/detail/content
or accessibility state is applied, that a fresh replacement-generation request succeeds, and that
all gateway and controller work counts reach zero. Keep the existing active-callback reentrancy,
queued-rejection reentrancy, and three-coordinator linearization regressions unchanged.

The renderer and composer remediation is otherwise structurally sound: cancellation precedes service
replacement, claimed deliveries retain exact tracker ownership through their MainActor discard, and
cleanup joins both preparation workers and delivery trackers. Module boundaries remain intact; the
root package still excludes Viewer, has no dependencies, targets iOS 16/macOS 13 in Swift 5 language
mode, and the Viewer project remains macOS 13/Swift 5 with only the local root-package dependency.
`git diff --check`, strict OpenSpec validation, and `swift package dump-package` pass. Configured
signing and embedded-entitlement verification remains deferred to Goal-level `release-hardening` and
is not a finding.

**Unresolved findings: 1**
