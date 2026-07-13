# Architecture and API Implementation Review - Round 11

Date: 2026-07-14

## Result

No actionable architecture or API finding remains after the round-10 remediation.

## Generation-zero token semantics

The gateway now gives generation zero two intentionally distinct delivery meanings without changing
the token's external identity or the normal generation path:

- A direct request made while no Store is installed creates a generation-zero token with no validity
  cell. `isDeliveryValid` therefore remains true and the synchronous `unavailable` result can reach
  presentation (`ViewerStoreExplorerGateway.swift:32-49, 501-515`).
- A `following:` request whose predecessor is invalid, absent, or from another generation creates a
  generation-zero token backed by a newly invalidated validity cell. Its synchronous
  `storeReplaced` result is therefore delivery-invalid (`ViewerStoreExplorerGateway.swift:51-59,
  519-533`).
- An admitted Store operation continues to carry the installed generation's shared validity cell,
  so replacement invalidates ordinary asynchronous and synchronously sealed results through the
  same mechanism (`ViewerStoreExplorerGateway.swift:1000-1010`).

The rejected-successor branch executes after releasing the gateway lock and does not submit work to
the currently published generation. Query, page, and gap gateway tests use a real replacement
generation and assert that all three returned tokens are invalid, no replacement operation exists,
and only a later explicit request uses the replacement (`ViewerStoreTests.swift:2048-2124`). This
closes `ARCH-R10-001` without weakening direct no-Store delivery.

## Handler-to-successor replacement races

The production driver preserves the exact gateway token from traversal release through query, page,
and gap submission. Every completion owns a one-time delivery box. A synchronously invoked callback
queues its MainActor work, the returned token is attached before that task can handle the result, and
`validToken` rejects the new invalid token before any failure, timeline, gap, progress, or
presentation mutation (`ViewerEventExplorerCoordinator.swift:45-83, 109-152, 495-590`). The work
tracker completion remains outside the presentation guard, so a discarded synchronous result still
retires its exact identity.

The coordinator regression independently exercises release-to-query rejection and query-to-page/gap
rejection. It verifies no successor presentation is applied, the state is not changed to failed,
all tracked work reaches zero, and a later explicit traversal reaches ready
(`ViewerFoundationTests.swift:5687-5775`). The real-gateway test supplies the production
retired-predecessor token behavior used by that coordinator path; together they cover both sides of
the prior handler-check-to-successor window without permitting retargeting.

The round-10 correctness remediation also makes page and gap guards independently sensitive. The
page phase uses a nonempty Event sentinel while the gap succeeds, and the gap phase uses a nonempty
gap sentinel while the page succeeds. Neither sentinel is published, neither rejected phase reaches
ready, work returns to zero, and a final explicit traversal succeeds
(`ViewerFoundationTests.swift:5534-5683`).

## Prior architecture and compatibility guarantees

The round-10 token change is local to the Viewer-internal gateway and coordinator. It does not alter
the commit-aware export boundary, its content-free terminal-success exception, destination
ownership, cancellation state machine, or joined runtime cleanup. The round-10 remediation evidence
records a complete Viewer run with 274 passes, two skips, and zero failures, a 537-test package run,
and a successful workspace build after the token and fixture changes. The prior export cancellation,
post-commit replacement, delayed destination, and lifecycle results therefore remain applicable.

No public SDK surface was added. The Core wire additions remain under the existing
`NearWireInternal` SPI and preserve encoded wire output. The root package still has no external
dependencies, declares iOS 16/macOS 13 and Swift 5 language mode, and contains no Viewer target. The
Viewer project remains macOS 13/Swift 5 with complete strict concurrency, one local root-package
product, no remote package, and no shell-script build phase.

The updated design and capability scenarios now explicitly require a synchronously rejected
successor to carry invalid delivery identity and produce no presentation change
(`design.md:124-137`; `specs/viewer-event-explorer-control/spec.md:158-163`). Implementation, tests,
and remediation evidence agree with that contract.

## Fresh validation

- Four focused direct-unavailable, retired-successor, synchronous-coordinator-rejection, and
  independent-stage tests passed with zero failures.
- `git diff --check` passed.
- Strict OpenSpec validation passed.
- Recursive strict Swift format lint passed.
- `swift package dump-package` passed and confirmed zero dependencies, iOS 16, macOS 13, Swift 5,
  and no Viewer target.

The macOS test host emitted unrelated `com.apple.linkd.autoShortcut` availability diagnostics; the
selected tests and build completed successfully.

Configured distribution signing and validation of entitlements embedded in a signed product remain
deferred to the Goal-level `release-hardening` change by product-owner decision and are not a finding.

**Unresolved findings: 0**
