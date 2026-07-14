# Pre-Implementation Architecture and API Review — Round 4

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Approved for implementation from the architecture/API dimension.** This fresh artifact review found
no unresolved architecture, API, ownership, compatibility, or module-boundary issue. The Round 3
freshness and gap-contract findings are closed without requiring a new public SDK API, wire field,
SQLite migration, package product, dependency, or second runtime owner.

Configured signing and inspection of entitlements embedded in a signed product remain deferred by
product-owner decision to Goal-level `release-hardening`. That deferred gate is not a finding in this
review.

## Fresh Scope Reviewed

- The current README, proposal, design, tasks, and all five capability deltas were reread in full.
- All three Round 3 reports and `pre-review-remediation-round3.md` were reread in full. Their conclusions
  were treated as inputs to verify, not inherited approvals.
- Existing Store gap rows/schema and reason producers, live projection gap counters, presentation
  generation tokens, Core/SDK product topology, and Viewer linkage were inspected only to verify that
  the revised contracts fit real internal types and owners.
- Comparator completeness, cache identity, traversal ownership, raw-event authority, cleanup, resource
  accounting, compatibility, and the previously closed Core inventory issue were rechecked.

## Round 3 Remediation Status

### Closed: freshness receipt and deadline ownership

Every card result now carries source generation, exact latest-Event identity, an absolute Viewer-
monotonic deadline, and a monotonically advancing deadline revision. The MainActor delivery gate
validates that complete receipt and the injected clock at both claim and apply. At or after equality,
charts may publish but cards are restated as No recent sample and no elapsed deadline is armed
(`design.md:155-163`; `specs/viewer-performance-dashboard/spec.md:144-152,221-227`). This closes the
late-scan and claimed-delivery reversal described by R3-CT-1.

Ownership remains singular. One lifecycle-owned dashboard controller validates delivery, owns the one
replaceable future-only deadline, handles Pause/Resume and replacement ordering, and releases deadline,
delivery, and cache state during cleanup. The MainActor model carries presentation state and receipt
values but does not become another scheduler (`tasks.md:20,24-25`; `design.md:213-219,229-247`). A
callback can mutate only the still-current full receipt, fires at most once, and cannot re-arm elapsed
work. Source/runtime replacement invalidates the receipt before joined cleanup, while paused expiry
uses one bounded dirty bit. The barrier matrix in tasks includes scan completion, claim, apply,
Pause/Resume, and replacement (`tasks.md:42`).

The receipt is a Viewer-internal delivery contract built from existing journal/durable identities and
generation concepts. It requires no Core/SDK public surface or encoded-event change. The existing
`ViewerExplorerPresentationToken` already demonstrates the internal runtime-plus-generation boundary
shape (`Viewer/NearWireViewer/Application/ViewerEventExplorerModel.swift:14-17,315-319,363-378`), so
the proposed dashboard-specific receipt is implementable without changing shared public API.

### Closed: normalized gap mapping and live overflow receipt

The normalized boundary now enumerates six closed kinds and three applicability values, gives a
case-sensitive exact/prefix mapping for every recognized Store reason family, maps all four schema-2
direction values, and uses conservative unknown defaults. Irrelevant Viewer-to-App evidence is counted
without breaking App-to-Viewer performance; uncertain or interval-less applicable evidence remains
Unplaced rather than guessed (`design.md:169-195`; `specs/viewer-local-store-search/spec.md:28-46`;
`specs/viewer-performance-dashboard/spec.md:158-181`). This closes the classification ambiguity in
R3-CT-2.

The mapping fits the current Store boundary. `GapVersions.directions` is closed to `unknown`,
`appToViewer`, `viewerToApp`, and `both`; raw rows currently expose bounded reason, direction, count,
and wall interval values (`Viewer/NearWireViewer/Store/ViewerStoreSchema.swift:363-380`;
`Viewer/NearWireViewer/Store/ViewerStoreDiagnostics.swift:16-30`). Current producers use the specified
`missingInitialEvent.*`, storage, store, journal, lifecycle, live-start/retry, and overflow families,
with unrecognized future values conservatively mapping to unknown
(`Viewer/NearWireViewer/Store/ViewerEventStore.swift:748,919`;
`Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:430-440,485-570,601-720,836-879,1014`). The
new performance traversal can therefore normalize inside Store without changing schema 2 or altering
the existing raw Explorer diagnostics API.

The current live projection already owns bounded ingress/window overflow, resident conflict,
diagnostic loss, Store-unavailable, and recovery counters
(`Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift:48-64,1445-1463`). The revised
performance live-slice wrapper adds only an internal saturating applicable-loss total and
`hasMoreApplicableGaps`, retains at most 128 normalized carriers, and preserves overflow evidence at
127/128/129 boundaries (`design.md:188-195`; `tasks.md:9,12,19,38,41`). This remains one slice from the
existing live projection executor, not a second live projection, transport, or persistence path.

## Module, API, and Single-Owner Audit

- Core remains the sole owner of the platform-neutral 16-key performance vocabulary through existing
  `NearWireInternal` SPI. SDK collection and Viewer decoding consume it; neither gets a duplicate raw-
  string inventory or new public product.
- Store owns raw Event/gap traversal, schema-2 normalization, frozen uppers, and the finite lease under
  the existing query arbiter. Projection owns bounded reduction and immutable results. The lifecycle
  dashboard controller owns refresh, delivery, freshness, cache, and cleanup. SwiftUI owns rendering
  only.
- The analysis-mode coordinator serializes Events/Performance traversal handoff. It does not duplicate
  the Event Explorer controller, session manager, Store, composer, query arbiter, or live projection.
- Raw Events and gaps remain authoritative. Normalized carriers, buckets, receipts, and charts are
  rebuildable Viewer memory and create no derived export, database, backfill, restoration, or content-
  bearing reflection path.
- Canonical journal and cache comparators remain complete and locator-independent. The gap and
  freshness remediation adds no comparator field to those identities and does not weaken exact cache
  equality or live-to-durable reconciliation.
- The change remains compatible with Xcode 16+, Swift 5 language mode, iOS 16 SDK consumers, macOS 13
  Viewer, root SwiftPM/CocoaPods delivery, and system Swift Charts. No third-party runtime dependency,
  entitlement, package manifest product, or podspec topology change is required.

## Source-Mutation Audit

`git status --short`, `git diff --name-only`, `git diff --cached --name-only`, and
`git ls-files --others --exclude-standard` show only the untracked active
`openspec/changes/viewer-performance-dashboard` directory. No production or test source is modified or
staged. Round 4 added only this evidence report.

## Findings

No P0, P1, or P2 architecture/API findings.

## Validation

- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive`
  - Exit 0: `Change 'viewer-performance-dashboard' is valid`.
- `env DO_NOT_TRACK=1 openspec show viewer-performance-dashboard --json --deltas-only`
  - Exit 0; 11 deltas were reported.
- `git diff --check -- openspec/changes/viewer-performance-dashboard`
  - Exit 0 with no output after this report; a separate trailing-whitespace scan of the untracked report
    also returned no output.
- Implementation tests were not run because this was an artifact-only pre-implementation review.

**Unresolved findings: 0**
