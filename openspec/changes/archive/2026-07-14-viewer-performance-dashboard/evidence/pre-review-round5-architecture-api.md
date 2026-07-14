# Pre-Implementation Architecture and API Review — Round 5

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Approved for implementation from the architecture/API dimension.** This fresh artifact-only review
found no unresolved architecture, API, ownership, compatibility, or module-boundary issue. The two
Round 4 correctness findings are closed by Viewer-internal receipt and Store-wrapper contracts that
need no public API, wire-format, schema, package-product, dependency, or persistence change.

Configured signing and inspection of entitlements embedded in a signed product remain deferred by
product-owner decision to Goal-level `release-hardening`. That deferred gate is not a finding in this
review.

## Fresh Scope Reviewed

- The current README, proposal, design, tasks, and all five capability deltas were reread in full.
- All three Round 4 reports and `pre-review-remediation-round4.md` were reread in full. Their verdicts
  were treated as claims to recheck, not inherited conclusions.
- Existing recording/device monotonic metadata, Event receive time, Store query budget and gap
  traversal, raw gap schema/API, live gap counters, query arbiter/gateway, package topology, and Viewer
  Core linkage were inspected only to verify implementability and ownership.
- All previously reviewed areas were rechecked: raw authority, Core inventory ownership, comparator
  completeness, cache and traversal ownership, live/durable reconciliation, bounded accounting,
  cleanup, privacy, compatibility, and absence of a migration or second runtime owner.

## Round 4 Finding Status

### Closed: current-only deadline and historical frozen-domain ownership

The artifacts now split card freshness by source domain. A current result carries source generation,
latest journal key, absolute Viewer-monotonic deadline, and deadline revision. The MainActor claim and
apply gates compare the complete receipt with the injected current-uptime clock; one future-only wake
can expire that receipt and cannot re-arm elapsed work (`design.md:155-163,228-235`;
`specs/viewer-performance-dashboard/spec.md:144-152,242-249`).

Historical cards carry no absolute current-uptime deadline and schedule no wake. They evaluate once
against a frozen upper in the same recording monotonic domain, using checked distance to the same
metric horizon; Pause does not age that frozen state. Current/historical switching invalidates and
joins the predecessor receipt before the successor evaluates in its own domain
(`design.md:165-170,230-235`; `specs/viewer-performance-dashboard/spec.md:154-159,281-285`). This closes
R4-CT-1 without inventing a clock conversion.

The split remains one ownership model, not two schedulers. The lifecycle-owned dashboard controller
owns the optional current deadline, delivery gate, Pause/Resume ordering, receipt invalidation, cache,
and cleanup. The MainActor model carries distinct current-deadline or historical-frozen-anchor receipt
state but owns no timer (`tasks.md:20,24-25`; `design.md:245-263`). A source-domain enum or equivalent
internal value is sufficient to make historical wake construction unrepresentable while retaining one
controller and one projection pipeline.

This contract fits existing data. Viewer persists recording/device start and end monotonic values and
Event receive monotonic time (`Viewer/NearWireViewer/Store/ViewerStoreCatalog.swift:27-38,45-61`;
`Viewer/NearWireViewer/Store/ViewerStoreSchema.swift:245-261,285-316`). Normally ended historical
devices can use their exact same-domain end. An interrupted recording can derive its frozen upper
under the already frozen Event upper, or use the original start for an empty session, without comparing
to current uptime or adding a column. The simulated-reset and current/historical barrier tests in
tasks 6.4 and 6.5 make accidental use of recovery-process uptime detectable (`tasks.md:41-42`).

### Closed: generic Store pagination versus applicable overflow

The fixed Store gap-page wrapper now separates generic `hasMoreRows` from a saturating performance-or-
uncertain count and `hasMoreApplicableGaps`. Store owns normalization and classification across the
complete frozen matching metadata scope. Hidden irrelevant-only rows affect generic pagination only;
hidden performance/uncertain evidence affects applicable overflow; classification budget exhaustion
sets applicable overflow conservatively and never claims completeness
(`design.md:176-210`; `specs/viewer-local-store-search/spec.md:28-52`;
`specs/viewer-performance-dashboard/spec.md:165-196`). This closes the indistinguishable-tail contract
in R4-CT-2.

The carrier and wrapper remain performance-specific Viewer internals. Existing raw Explorer gap rows
may continue to expose bounded namespace/reason/direction strings, while only fixed 256-byte normalized
carriers cross the new performance projection boundary. `GapVersions` remains schema 2 with the four
closed direction values, and the existing raw page API stays an internal Viewer diagnostic surface
(`Viewer/NearWireViewer/Store/ViewerStoreSchema.swift:363-380`;
`Viewer/NearWireViewer/Store/ViewerStoreDiagnostics.swift:16-36,100-180`). No public SDK or Core type
needs to learn about pagination or applicability.

Classification also preserves the existing Store owner and budget. `ViewerSQLiteBudget.query` already
provides the required 2,000,000-step and 250-ms boundary, cancellation is enforced by the connection
progress handler, and the current gap traversal is gateway/arbiter-owned
(`Viewer/NearWireViewer/Store/ViewerSQLite.swift:136-146,365-410`;
`Viewer/NearWireViewer/Store/ViewerStoreExplorerGateway.swift:709-724`). The performance traversal can
stream fixed metadata and counters without retaining a second row collection. If the classification
statement reaches its budget, the already specified conservative fixed flag is enough; no retry loop,
side cache, schema change, or unbounded scan is required.

The Store wrapper stays 512 bytes and a page stays 8,704 bytes. The live path retains its existing
single projection executor and fixed counter source; its separate slice wrapper uses the same
applicable-count/overflow semantics without creating a second live projection
(`Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift:48-64,1445-1463`; `tasks.md:9-12`).
Paired identical-retained 129-row fixtures, budget failure, and mixed Store/live boundaries provide an
independent API oracle (`tasks.md:38,41`).

## Module, API, and Single-Owner Audit

- Core remains the sole owner of the platform-neutral 16-key metric vocabulary through existing
  `NearWireInternal` SPI. SDK collection and Viewer decoding consume it without changing public App
  API, encoded JSON, validation, collection behavior, or unknown-key handling.
- Store owns frozen Event/gap traversal, metadata normalization/classification, pagination receipts,
  and its finite lease under the one query arbiter. Projection owns bounded reduction. The lifecycle
  controller owns refresh, delivery, optional current freshness wake, cache, and cleanup. SwiftUI owns
  rendering only.
- One analysis-mode coordinator still serializes Events/Performance traversal handoff. The remediation
  adds neither a second session manager, Store, Explorer controller, query arbiter, live projection,
  raw cache, nor timer owner.
- Raw Events and gaps remain authoritative. Current/historical receipts, normalized carriers, buckets,
  and charts are fixed, rebuildable Viewer memory with no derived export, restoration, database,
  trigger, index, backfill, or migration.
- Canonical journal and cache comparators remain complete and locator-independent. Source-domain
  freshness state and wrapper overflow metadata do not alter journal identity, cache identity, LRU
  order, or live-to-durable reconciliation.
- Root SwiftPM/CocoaPods delivery, Viewer linkage to `NearWireCore`, Xcode 16+, Swift 5 language mode,
  iOS 16 SDK consumers, macOS 13 Viewer, and system Swift Charts remain compatible. No entitlement,
  third-party runtime, root product, podspec subspec, or package dependency change is required.

## Source-Mutation Audit

`git status --short`, `git diff --name-only`, `git diff --cached --name-only`, and
`git ls-files --others --exclude-standard` show only the untracked active
`openspec/changes/viewer-performance-dashboard` directory. No production or test source is modified or
staged. This review wrote only `pre-review-round5-architecture-api.md`; another independent Round 5
report may coexist in the shared evidence directory.

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
