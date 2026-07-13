# Security, Performance, and Documentation Implementation Review — Round 8

Date: 2026-07-14

## SPD-R8-001 — P1 High: claimed renderer/composer deliveries remain request-unbounded

Confidence: 10/10

The round-7 remediation gives every renderer generation and composer attempt an exact delivery gate
and tracker identity, but it does not bound the number of results that may claim delivery before the
MainActor consumes them.

- `ViewerEventExplorerController.submitRenderer` cancels only the current delivery, creates a new
  tracker identity, and lets every completion that wins its individual gate create a distinct
  `Task { @MainActor ... }` (`ViewerEventExplorerController.swift:1701-1726`). When supersession finds
  an already-claimed delivery, `cancelRendererDelivery` intentionally leaves that tracker identity
  alive for its queued task (`1843-1855`). The controller no longer retains the delivery record, but
  the task still captures the renderer result and the tracker retains its UUID.
- `ViewerControlComposerController.send` and `cancelPreparationDelivery` have the same ownership
  pattern (`ViewerControlComposerController.swift:220-257, 365-384`). A claimed task can retain the
  immutable prepared Event and its content until MainActor execution.
- The preparation services bound only executing plus pending requests. After invoking completion,
  each serial worker can consume the next pending request without waiting for the prior MainActor
  delivery (`ViewerRendererRegistry.swift:630-650` and
  `ViewerComposerPreparation.swift:468-488`). Therefore their two-request bound is not a bound on
  escaped claimed results or tasks.

This has a deterministic adversarial schedule. From one synchronous `@MainActor` call stack, submit
a request, block that stack on a semaphore until the background `deliveryClaimed` hook signals, then
supersede and repeat without yielding the MainActor. Each worker result claims before supersession,
each supersession preserves the claimed tracker, and none of the queued MainActor tasks can run until
the loop returns. The number of tracker identities, tasks, derived renderer results, or prepared
Events therefore grows with the loop count. Cleanup will eventually join them, but it is neither
constant-bounded nor predictably finite under continued admitted work.

The new 100,000-replacement tests do not exercise this schedule: they block the preparation executor,
so all replacements are cancelled *before* any delivery claim
(`ViewerFoundationTests.swift:6066-6121` and `ViewerFlowControlTests.swift:1640-1696`). The other two
tests cover exactly one claimed result. Their passing results establish the two intended endpoints,
not the missing many-claimed interleaving. The round-7 remediation evidence consequently overstates
that result delivery is bounded. This contradicts the no-unbounded-MainActor-chain design
(`design.md:398-406`), the task/resource-bound documentation
(`Documentation/Viewer-Event-Explorer.md:307-317`), and the cleanup/privacy requirement that named
content work remain bounded and joined (`specs/viewer-event-explorer-control/spec.md:134-150`).

Impact: a blocked or synchronously busy MainActor combined with repeated selection/send supersession
can retain request-proportional content-bearing results. Composer content can approach its active
multi-megabyte limit per successful preparation, so this can create severe memory pressure or
termination despite the advertised preparation and task bounds.

Required remediation:

- Add one controller-level result-delivery pump per renderer/composer owner, with a hard retained
  result/task bound. A completion should replace one pending result in a lock-protected slot and
  schedule at most one MainActor drain, or preparation must not advance until the one prior delivery
  is acknowledged. Per-generation gates alone are insufficient.
- Release a displaced result outside the delivery lock, preserve exact generation rejection, and
  make cleanup cancel/join the one pump before reporting zero content work.
- Add deterministic MainActor-blocked regressions that use a semaphore acknowledgement for every
  successful delivery claim, supersede without yielding, and prove the retained result/task/tracker
  count stays at the declared constant for both renderer and composer. Include maximum legal content
  and verify cleanup releases every displaced value.

## SPD-R8-002 — P2 Medium: the save-panel callback escapes lifecycle cancellation

Confidence: 10/10

`ViewerExportFlowView.chooseDestination` starts a modeless `NSSavePanel` and its escaping completion
strongly captures the old explorer controller. An accepted response unconditionally creates another
MainActor task (`ViewerEventExplorerView.swift:861-873`). The panel and task have no runtime/export
generation, delivery gate, cancellation owner, or cleanup receipt.

After `ViewerEventExplorerController.sealAndClear` clears export state to `.idle`
(`ViewerEventExplorerController.swift:1155-1198`), a later panel response calls
`executePreparedExport`. Its failed guard includes `!sealed`, but the failure branch writes
`.failed(.invalidRequest)` and publishes a revision (`1060-1066`). A delayed UI callback can therefore
repopulate state after the documented cleanup has completed. The callback also retains the old
controller and operator-selected destination until it runs, even though no export operation remains
owned by the controller.

No file is written in this sealed path, so this is not an export-content disclosure. It is still a
lifecycle/privacy ownership defect and directly contradicts the operator statement that late
callbacks cannot repopulate cleared state (`Documentation/Viewer-Event-Explorer.md:332-342`) and the
generation requirement for export/result completions
(`specs/viewer-event-explorer-control/spec.md:134-136`). Current export tests cover store execution,
atomic destination replacement, and controller operation callbacks; they do not delay the native
save-panel response across runtime sealing.

Required remediation:

- Give destination selection one exact lifecycle generation and at most one owned panel response.
  Cancel/dismiss or invalidate it when the export flow, view, or runtime is sealed, and weakly capture
  the controller across the AppKit callback.
- A call received after sealing must be a no-op before mutating presentation state. Do not turn
  lifecycle invalidation into an operator-visible invalid-request failure.
- Add an injectable save-panel seam and a regression that acknowledges disclosure, delays the panel
  response, seals the runtime, then returns an approved URL. Assert no MainActor work/state revision,
  no export request/file, no retained destination, and no old-controller retention after cleanup.

## Reviewed areas and validation

The gateway replacement remediation was reviewed for lock order, arbitrary callback reentrancy,
generation publication, operation retirement, cancellation cleanup, and lease lifetime. Transition
ownership is released before deferred callbacks, active operation/group/cancellation ownership is
retired before arbitrary completion, and the current three-generation regression covers the prior
orphan-generation interleaving. No new gateway deadlock or leak finding was identified.

Privacy scans found no received/stored Event clipboard, drag, share, logging, preference, analytics,
or restoration path. Export disclosure still states that content may be sensitive, aliases are
pseudonyms, output is unencrypted, output is outside Viewer retention/quota, and the destination may
sync or back up the file. Secure sibling creation, nonsymlink checks, owner-only temporary mode,
pre-commit cleanup, and atomic replacement remain intact.

No production script, shell build phase, remote package, root-package dependency, nested manifest,
or Core/SDK runtime dependency was added. The root package remains Swift 5 with iOS 16 and macOS 13
platform declarations and no external dependencies.

Independent validation:

- Focused round-7 remediation XCTest set: 9 tests passed, 0 failures.
- Strict OpenSpec validation: passed.
- Strict recursive Swift format lint: passed.
- `swift package --disable-sandbox dump-package`: passed; cache warnings were environmental only.
- Project, Info.plist, and entitlement plist parsing: passed.
- `git diff --check`: passed.

Configured signing and embedded-entitlement validation remains explicitly deferred to the final
Goal-level `release-hardening` change and is not a finding in this review.

**Unresolved findings: 2**
