# Pre-Implementation Architecture and API Review — Round 3

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Approved for implementation from the architecture/API dimension.** This fresh artifact review
found no unresolved architecture, API, comparator, or module-boundary issue. The sole Round 2
architecture finding is closed by a schema-owned Core SPI inventory and explicit SDK/Viewer reuse.

Configured signing and inspection of entitlements embedded in a signed product remain explicitly
deferred by product-owner decision to Goal-level `release-hardening`. That deferred gate is not a
finding in this review.

## Fresh Scope Reviewed

- The current proposal, design, task list, all five capability deltas, the Round 2 architecture/API
  report, and `pre-review-remediation-round2.md` were reread in full.
- Existing Core performance schema, SDK performance projection, Viewer journal/source identities,
  package and CocoaPods topology, Viewer Xcode linkage, and runtime generation boundaries were read
  only to verify that the proposed contracts fit real module and identity shapes.
- No conclusion from Round 2 was inherited without current artifact and source-boundary evidence.

## Round 2 Finding Status

### Closed: canonical ownership of the fixed 16-key vocabulary

The new `performance-snapshot-schema` delta enumerates all 16 raw values in one exact order and makes
Core `NearWireInternal` SPI the sole owner of their group and numeric/categorical/unavailable-only
kind (`specs/performance-snapshot-schema/spec.md:3-40`). The proposal now includes the Core/SDK move
and accurately expands impact beyond Viewer-only source (`proposal.md:13-14,45-54`). The design and
tasks require the SDK duplicate to be removed, both SDK and Viewer to consume Core, and tests to
detect a second raw-string inventory (`design.md:38-47`; `tasks.md:6-12,16,38-40`).

This ownership fits the existing topology: `NearWirePerformance` already depends on `NearWireCore`
in SwiftPM (`Package.swift:70-79`), the Viewer already links the root `NearWireCore` product
(`Viewer/NearWireViewer.xcodeproj/project.pbxproj:181-190,261-267`), and CocoaPods compiles Core into
the module consumed by its Performance subspec (`NearWire.podspec:33-43,55-63`). Moving the internal
enum therefore needs no new product, dependency, manifest, or Viewer-only package.

## Comparator Completeness

- The canonical journal comparator covers every stored field of `ViewerEventJournalKey` in the same
  explicit order: runtime UUID bytes, connection UUID bytes, direction ordinal, and unsigned wire
  sequence (`Viewer/NearWireViewer/Session/ViewerCommittedEventObservation.swift:12-17`;
  `design.md:100-106`; `specs/viewer-performance-dashboard/spec.md:52-56`). Both current direction
  cases have fixed ordinals, UUID representation is fixed to network-order bytes, and locator state
  is deliberately excluded because live-to-durable reconciliation must not change identity.
- The cache comparator covers its complete normative identity after the source-kind tag: variant
  source/device identity, range kind, lower/upper bounds, Store generation, frozen Event/gap uppers,
  runtime UUID, live generation, and slice revision. It fixes source/range ordinals, UUID bytes,
  positive row-ID representation, integer ordering, and the exact field order
  (`design.md:95-106`; `specs/viewer-performance-dashboard/spec.md:70-81`). The source-kind tag makes
  current UUID and historical row-ID variants disjoint, so no unspecified optional-value ordering is
  needed. Tasks require mutation-sensitive equal-tie coverage for both comparators
  (`tasks.md:18,40`).

## Module and API Boundary Audit

- The inventory is platform-neutral schema vocabulary and therefore belongs in Core. Collection
  behavior remains in SDK and dashboard projection/presentation remains in Viewer.
- The inventory is expressly `NearWireInternal` SPI. The capability delta forbids changes to public
  App API, encoded JSON, validation, collection side effects, and unknown-key forward compatibility
  (`specs/performance-snapshot-schema/spec.md:25-40`). This is compatible with the existing Core SPI
  pattern and does not alter the public NearWire/NearWirePerformance product surface.
- Raw Events remain the only source of truth. The change adds no SQLite migration, derived Store,
  second session manager, second query arbiter, second live projection, or root-package dependency.
- Store traversal, Performance projection, UI, and analysis-mode coordination remain within Viewer;
  shared source selection and exact identity-only raw reveal preserve the existing Explorer boundary.
- macOS 13, iOS 16, Swift 5 language mode, system Charts, SPM, and CocoaPods boundaries remain
  compatible with the proposed work.

## Source-Mutation Audit

`git status --short`, `git diff --name-only`, `git diff --cached --name-only`, and the untracked-file
listing show only the active `openspec/changes/viewer-performance-dashboard` directory. No production
or test source is modified or staged. Round 3 added only this evidence report.

## Findings

No P0, P1, or P2 architecture/API findings.

## Validation

- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive`
  - Exit 0: `Change 'viewer-performance-dashboard' is valid`.
- `env DO_NOT_TRACK=1 openspec show viewer-performance-dashboard --json --deltas-only`
  - Exit 0; parsed 11 deltas, including `performance-snapshot-schema`.
- `git diff --check -- openspec/changes/viewer-performance-dashboard`
  - Exit 0 with no output after this report.
- Implementation tests were not run because this was an artifact-only pre-implementation review.

**Unresolved findings: 0**
