# Requirement-to-Evidence Audit

Date: 2026-07-14
Change: `viewer-event-explorer-control`

## Audit method

This audit maps every requirement in the three delta specifications to implementation evidence,
normative test evidence, and the aggregate validation gate. Evidence is accepted only when it
exercises the requirement's stated count, byte, generation, token, lease, page, cursor, wake, VM,
or logical-deadline bounds; host timing and process-memory observations remain diagnostic context.

Configured distribution signing and inspection of entitlements embedded in a signed product are
deferred by product-owner decision to the Goal-level `release-hardening` change. This change keeps
the source/project/privacy gates and unsigned runtime coverage, but does not claim the deferred
signed-product gate passed.

## Requirement matrix

| ID | Delta requirement | Implementation evidence | Test and validation evidence | Audit result |
| --- | --- | --- | --- | --- |
| MD-1 | Device workspace exposes session control and composes with the Event Explorer | `apply-5.1-native-workspace-shell.md`, `apply-5.2-event-explorer-ui.md`, `apply-5.5-keyboard-accessibility-privacy.md` | `test-6.2-catalog-timeline-diagnostics.md`, `test-6.5-presentation-renderers.md`, `test-6.7-blocked-cleanup.md` | Covered: one workspace and protocol owner preserve pairing, approval, rates, telemetry, safe rows, explorer scope, deterministic state, and accessibility. Performance charts remain explicitly outside this change. |
| MD-2 | Multi-device owner exposes bounded live presentation and typed control admission without transferring protocol ownership | `apply-3.1-runtime-components.md` through `apply-3.5-control-capabilities.md`, `apply-4.2-source-neutral-scope.md`, `apply-4.5-incremental-composer-preparation.md`, `apply-5.4-multi-target-control-composer.md` | `test-6.3-shared-observation-live.md`, `test-6.4-control-composer-privacy.md`, `test-6.7-blocked-cleanup.md`; 100,000-offer and authority-horizon gates in `validation-6.9-aggregate.md` | Covered: exact runtime bundle, normalized observation, bounded live ownership, duplicate horizon, durable reconciliation, immutable prepared draft, opaque capabilities, terminal cache, truthful ordered admission, and joined cleanup. |
| LS-1 | Viewer owns one local SQLite store with explicit schema and failure boundaries | `apply-2.1-schema-migration.md`, `apply-2.2-explorer-gateway.md`, `apply-2.3-query-arbiter.md` | `test-6.1-migration-query-races.md`, `test-6.7-blocked-cleanup.md`; large schema-1 migration and raw SQLite diagnostic gates in `validation-6.9-aggregate.md`; lifecycle hardening in `implementation-review-round11-remediation.md` and `implementation-review-round12-remediation.md` | Covered: schema 2, migration-only connection/settings, capacity/cancellation/rollback/probes, normal pool publication, exact query tokens, duplicate authority, unavailable/recovery boundaries, secure files, joined close, and zero raw SQLite API-violation matches. |
| LS-2 | JSON export streams a complete session or frozen filtered result | `apply-2.6-history-export-gateway.md`, `apply-5.3-recording-operations-export.md` | `test-6.6-history-export-integration.md`; commit-boundary and generation-race regressions in `implementation-review-round6-remediation.md`, `implementation-review-round9-remediation.md`, and `implementation-review-round10-remediation.md` | Covered: immutable scope, finite lease, deterministic streaming envelope, atomic destination, disclosure, preflight, exact cancellation, authoritative post-commit completion, and no import or destination persistence. |
| LS-3 | Store exposes bounded explorer catalogs, diagnostics, detail, and mutation facades | `apply-2.2-explorer-gateway.md` through `apply-2.6-history-export-gateway.md`, `apply-4.1-explorer-presentation-model.md` | `test-6.1-migration-query-races.md`, `test-6.2-catalog-timeline-diagnostics.md`, `test-6.6-history-export-integration.md`, `test-6.7-blocked-cleanup.md`; traversal-generation regressions in rounds 7 through 10 | Covered: immutable gateway leases, frozen catalogs, exact query/gap/causality/detail bounds, accepted plans, logical identity, revision-safe mutation, explicit restart, and predecessor-Store rejection. |
| EX-1 | Viewer presents one three-column Event Explorer with an explicit recording scope | `apply-4.1-explorer-presentation-model.md`, `apply-4.2-source-neutral-scope.md`, `apply-5.1-native-workspace-shell.md`, `apply-5.2-event-explorer-ui.md` | `test-6.2-catalog-timeline-diagnostics.md`, `test-6.5-presentation-renderers.md` | Covered: live/historical scope, bounded catalogs and resident model, exact one-through-16 logical device selection, three-column SwiftUI workspace, stable empty/loading/error states, and one explicit inspector/composer boundary. |
| EX-2 | Timeline pages use bounded Viewer receive order and explicit diagnostics | `apply-2.4-frozen-catalogs.md`, `apply-2.5-diagnostics-detail.md`, `apply-4.1-explorer-presentation-model.md`, `apply-5.2-event-explorer-ui.md` | `test-6.2-catalog-timeline-diagnostics.md`, `test-6.3-shared-observation-live.md`; aggregate paging/cursor/gap gates in `validation-6.9-aggregate.md` | Covered: Viewer receive ordering, row-ID tie breaks, frozen bidirectional keysets, 600-row residence, exact selection reload, 32-row gaps, disposition/transient presentation, and bounded causality diagnostics. |
| EX-3 | Live and historical search share one closed filter model | `apply-3.4-live-evaluation.md`, `apply-4.2-source-neutral-scope.md`, `apply-4.5-incremental-composer-preparation.md` | `test-6.1-migration-query-races.md`, `test-6.3-shared-observation-live.md`, `test-6.5-presentation-renderers.md` | Covered: one source-neutral validated model, exact AND/OR/presence semantics, durable/live differential behavior, bounded transient evaluation, FTS recorded-only guidance, immutable materialization, generation replacement, and no widening or replay. |
| EX-4 | Presentation Pause never pauses capture or creates backlog | `apply-3.3-bounded-live-projection.md`, `apply-4.1-explorer-presentation-model.md`, `apply-4.3-pause-reconciliation.md`, `apply-5.2-event-explorer-ui.md` | `test-6.3-shared-observation-live.md`, `test-6.5-presentation-renderers.md`, `test-6.7-blocked-cleanup.md`; 100,000-change-token gate in `validation-6.9-aggregate.md` | Covered: pre-freeze generation invalidation, fixed presentation, latest-only bounded state, no networking/store/control pause, one fresh resume traversal, Jump to Latest, exact lease release, and 10-Hz/one-wake refresh. |
| EX-5 | Event detail and renderer selection are bounded and fallback-safe | `apply-2.5-diagnostics-detail.md`, `apply-4.4-bounded-renderers.md`, `apply-5.2-event-explorer-ui.md` | `test-6.2-catalog-timeline-diagnostics.md`, `test-6.5-presentation-renderers.md`, `test-6.7-blocked-cleanup.md` | Covered: one canonical detail, raw/tree/log/table/numeric caps, work/time checkpoints, escaped structured previews, deterministic registry selection, Generic/refine fallback, exact generation cancellation, bounded causality, accessibility caps, and no third-party renderer loading. |
| EX-6 | Recording management and export preserve revisions, leases, and disclosure | `apply-2.6-history-export-gateway.md`, `apply-5.3-recording-operations-export.md` | `test-6.6-history-export-integration.md`, `test-6.7-blocked-cleanup.md`; export regressions in rounds 6, 8, and 9 | Covered: revision-safe metadata/pin/delete, active/leased protection, bounded confirmation, complete/filtered immutable scope, mandatory disclosure, native save panel lifetime, finite lease, atomic replacement, and no destination persistence. |
| EX-7 | Viewer-to-App control composition reports only local admission | `apply-3.5-control-capabilities.md`, `apply-4.5-incremental-composer-preparation.md`, `apply-5.4-multi-target-control-composer.md` | `test-6.4-control-composer-privacy.md`, `test-6.7-blocked-cleanup.md`; terminal-cache and 100,000-supersession gates in `validation-6.9-aggregate.md` | Covered: bounded editable inputs, one encode/traversal/copy, 1-through-16 opaque targets, authoritative manager classification, normal/keep-latest, exact TTL/content/model formula, `Queued locally`, no retry/retarget/history/template, and operator-only clipboard access. |
| EX-8 | Explorer updates and accessibility are bounded and privacy-aware | `apply-3.1-runtime-components.md`, `apply-4.1-explorer-presentation-model.md` through `apply-4.5-incremental-composer-preparation.md`, `apply-5.5-keyboard-accessibility-privacy.md` | `test-6.4-control-composer-privacy.md`, `test-6.5-presentation-renderers.md`, `test-6.7-blocked-cleanup.md`; delivery/generation/lifecycle regressions in rounds 6 through 10 | Covered: exact generations and atomic delivery handoffs, latest-only delivery pumps, bounded MainActor ownership, joined shutdown, complete content clearing, redacted reflection, safe status rows, keyboard/focus/non-color state, bounded accessibility text, and no received-content clipboard path. |

## Cross-cutting validation

`validation-6.9-aggregate.md` is the authoritative aggregate record for the unsigned production
build, complete Viewer suite, 537-test root suite, package/project/resource/privacy boundaries,
strict formatting, strict OpenSpec validation, migration and live structural limits, and diagnostic
versus normative measurement distinctions. The final Viewer result is
`/tmp/NearWire-Round11-FinalPoolOwnership.xcresult`: 276 total, 274 passed, two configured skips,
and zero failures. Its exported raw diagnostics have zero SQLite API-violation matches.

The two configured skips are explicitly bounded: one machine-local Application Support audit is
opt-in, and configured signing plus embedded-entitlement inspection is deferred to Goal-level
`release-hardening`. Neither skip is used as evidence for a requirement claimed by this change.

## Review and closure gate

Rounds 1 through 12 and their remediation records establish the finding/fix/revalidation history.
The fresh post-remediation Round 13 reports independently re-read the final source and corrected
evidence:

- `reviews/implementation-round-13-architecture-api.md`: zero unresolved findings;
- `reviews/implementation-round-13-correctness-testing.md`: zero unresolved findings; and
- `reviews/implementation-round-13-security-performance-documentation.md`: zero unresolved
  findings.

Strict change validation and diff hygiene pass after those reports. Every delta requirement now has
implementation and normative test evidence, every actionable review finding is resolved, and no
requirement relies on the deferred signing gate. The remaining mechanical closure steps are to
archive the change into canonical specifications, verify that the archived evidence is preserved,
and commit the archived state before `viewer-performance-dashboard` begins.

The first real archive preflight exposed a title-mapping omission and aborted without changing any
file. `archive-preflight-remediation.md` records the exact failure and the explicit
`RENAMED`-plus-`MODIFIED` correction. The fresh post-correction Round 14 closure reports each find
zero unresolved findings:

- `reviews/implementation-round-14-architecture-api.md` verifies canonical rename/apply ordering
  and preserved module ownership;
- `reviews/implementation-round-14-correctness-testing.md` verifies one rename, one complete
  modification, no requirement loss or duplication, and continued applicability of Round 13 test
  evidence; and
- `reviews/implementation-round-14-security-performance-documentation.md` verifies the privacy,
  performance, documentation, and deferred-signing boundaries and a successful isolated archive
  with 31 strictly valid canonical specifications.

The real archive subsequently completed as
`openspec/changes/archive/2026-07-13-viewer-event-explorer-control`. Post-archive verification found
all 31 canonical specifications strictly valid, the eight new Event Explorer requirements present,
the local-store and multi-device deltas correctly merged, the old history-free workspace title and
exclusion absent, the new title and privacy/dashboard-deferral clauses unique, all evidence/review
files preserved, and no active change. `archive-verification.md` records the exact results. The only
remaining work is the commit required by task 7.3.
