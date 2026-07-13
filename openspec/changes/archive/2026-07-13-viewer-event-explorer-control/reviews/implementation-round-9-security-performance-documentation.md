# Security, Performance, and Documentation Implementation Review — Round 9

Date: 2026-07-14

## SPD-R9-001 — P1 High: coordinator replacement can hide an already committed export

Confidence: 10/10

The round-8 shared generation-validity remediation correctly prevents claimed catalog, detail,
mutation, and pre-commit export results from reaching a replacement runtime. It also rejects the one
export result that must remain authoritative: success after the destination has already been
atomically replaced.

- Export execution crosses its irreversible commit point at `renameat`; after that succeeds,
  directory synchronization is best effort and the destination has already been replaced
  (`ViewerStoreExport.swift:386-395, 939-965`).
- The gateway deliberately marks export success as authoritative and preserves a successful
  candidate across `.cancelled` and `.storeReplaced` operation states
  (`ViewerStoreExplorerGateway.swift:792-810, 1014-1037`). It then retires gateway ownership before
  delivering that result (`926-943`).
- Runtime replacement unconditionally invalidates the old generation's shared delivery cell
  (`ViewerStoreExplorerGateway.swift:127-140`), and every old token observes that cell
  (`921-925`). The controller's generic `finish` then requires the token to remain delivery-valid
  before applying any result (`ViewerEventExplorerController.swift:1884-1892`).
- Consequently, replacement after `renameat` but before the MainActor callback causes the controller
  to discard the gateway's authoritative `.success`. `executePreparedExport` has already set the
  presentation to `.exporting` (`ViewerEventExplorerController.swift:1114-1140`), so no terminal
  state is applied. The export sheet remains non-dismissible and reports an active export
  (`ViewerEventExplorerView.swift:748-757, 780-788`). If the operator then presses **Cancel Export**,
  the UI reports that no partial file replaced a prior destination (`795-800`), even though the
  selected JSON file was fully committed.

This is a security/documentation correctness defect, not merely a stale-presentation issue. An
operator handling sensitive recorded Events can be falsely told that no destination was replaced
after an unencrypted external file was actually written. It directly contradicts the design and
operator documentation, both of which state that committed export success remains authoritative
across cancellation or runtime replacement (`design.md:331-341` and
`Documentation/Viewer-Event-Explorer.md:237-242`).

The focused tests do not cover this boundary. The committed-export test proves that the gateway
preserves success, while the controller-generation test proves rejection of an old claimed catalog
result. Neither drives an irreversibly committed gateway export through controller delivery after
the old generation cell is invalidated.

Required remediation:

- Keep shared generation invalidation for queries, catalog/detail results, mutations, and export
  outcomes that have not committed. Represent irreversible export success separately at the
  gateway-controller boundary so only the exact existing export operation may apply its terminal
  `.completed` state after replacement. It must not read from, mutate, or retarget the successor
  generation.
- Preserve the current ownership rule that retires gateway operation/group/cancellation state before
  arbitrary completion. Do not solve this by moving the callback back inside the gateway completion
  group or replacement lock.
- Add a deterministic controller-level regression that blocks result delivery after `renameat`,
  installs a replacement coordinator, then releases delivery. Assert that the selected file is the
  complete committed JSON document, presentation becomes `.completed(eventCount:)`, no exporting or
  cancelled message remains, the operation retires exactly once, the successor generation accepts a
  fresh request, and gateway/controller tracked work reaches zero.
- Retain a paired pre-commit replacement/cancellation test proving that the old destination is
  preserved and the result remains cancelled or store-replaced.

## Reviewed areas and validation

The round-8 result-delivery pumps were reviewed for retained-value bounds, displacement outside the
lock, exact generation rejection, tracker retirement, and cleanup joining. Renderer and composer now
retain at most the executing/pending service values plus the pump's active/pending values; no
request-proportional MainActor task chain remains. The save-panel lifecycle remediation was reviewed
for weak controller ownership, pre-claim cancellation, claimed-response joining, AppKit dismissal,
and sealed-controller no-op behavior. No unresolved round-8 finding remains in those areas.

Privacy scans found no received/stored Event clipboard, drag, share, logging, preference, analytics,
or restoration path. Received content remains non-editable and non-selectable. Export disclosure
still states that content may be sensitive, aliases are pseudonyms, output is unencrypted, output is
outside Viewer retention/quota, and its destination may synchronize or back up the file. Secure
sibling creation, owner-only temporary permissions, nonsymlink validation, pre-commit cleanup, and
same-directory atomic replacement remain intact apart from the terminal-presentation defect above.

No production shell build phase, remote package, root-package dependency, nested manifest, or
Core/SDK third-party runtime dependency was added. The root package remains Swift 5 with iOS 16 and
macOS 13 platform declarations and no external dependencies.

Independent validation:

- Focused round-8 remediation and export-semantics XCTest set: 5 tests passed, 0 failures.
- Strict OpenSpec validation: passed. The later PostHog flush failed because sandboxed DNS could not
  reach `edge.openspec.dev`; validation itself completed successfully.
- Strict recursive Swift format lint: passed.
- `swift package --disable-sandbox dump-package`: passed; user-cache warnings were environmental
  only.
- Project, Info.plist, and entitlement plist parsing: passed.
- `git diff --check`: passed.

Configured signing and embedded-entitlement validation remains explicitly deferred to the final
Goal-level `release-hardening` change and is not a finding in this review.

**Unresolved findings: 1**
