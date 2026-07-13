# Pre-Implementation Architecture/API Review — Round 2

## Verdict

**Not approved for implementation.** The round-1 architecture remediations are substantially
complete, but two contradictory normative scenarios remain. Both are actionable Medium findings;
approval requires correcting them and obtaining a fresh review with zero unresolved findings.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 0 |
| **Total actionable** | **2** |

## Scope and Method

This review independently reread the latest proposal, design, task plan, all three delta specs, all
three round-1 review reports, and the round-1 remediation note. It also checked the relevant
canonical store/session requirements and current Viewer seams for schema columns, coordinator
replacement, traversal leases and cancellation, runtime component construction, live journal
identity, session ownership, and downlink queue admission. The remediation note was treated as a
navigation aid, not as evidence that a finding was resolved.

The installed generic review skill references a `checklist.md` that is absent from that installation.
The repository-specific OpenSpec and AGENTS review gates were nevertheless completed in full.

## Round-1 Finding Disposition

| Round-1 finding | Round-2 disposition | Independent verification |
| --- | --- | --- |
| A1 — Runtime-scoped component ownership | Resolved | The design, Event Explorer delta, multi-device delta, and tasks now require one `makeRuntimeComponents(runtimeLogicalID:)` call per runtime, exact shared manager/handoff/control/live/journal identity, no downcast, the process store outside the bundle, and one ordered finite cleanup path across every stop/reset/failure case. |
| A2 — Coordinator-generation store ownership | Resolved | The local-store delta and tasks now make `ViewerStoreRuntime` the application gateway, prohibit retained coordinator services, bind requests and leases to the originating coordinator generation, and require seal/cancel/join/release-before-close with no implicit retargeting. |
| A3 — Exact query arbiter and lease ownership | **Not fully resolved** | The design, local-store delta, Event Explorer delta, and tasks now define one sole traversal/lease arbiter, enqueue-to-completion operation tokens, successor-safe exact cancellation, one-time traversal termination, and immutable filtered-export scope with an independent export lease. However, the normative export scenario still requires the existing traversal itself to stream the export; see R2-2. |
| A4 — Complete bounded live state | Resolved | The design and multi-device delta now define normalized shared observations, exact journal identity, later disposition, bounded session aliases, drops, session end, conflict/overflow and store-gap state, precise presence scopes, immutable snapshots, fixed live bounds, and joined clearing. |
| A5 — Total presentation retention | Resolved | The Event Explorer delta and tasks now cap recording, device, Event, gap, cursor/anchor, selection, and detail residency and define deterministic bidirectional eviction with exact reload or safe selection clearing. |
| A6 — Closed downlink admission API | Resolved | The design and both affected deltas now define exact runtime/manager/connection target tokens, duplicate handling, ordered per-target results, authoritative mutually exclusive classification, terminal-before/after-enqueue behavior, one prepared draft, and no retry, retargeting, delivery claim, or independent history. |

## Actionable Findings

### R2-1 — Medium — The recording catalog scenario still specifies the removed activity key

The local-store requirement establishes immutable descending recording row ID as the only recording
catalog order, explicitly prohibits mutable activity ordering, and binds the cursor to a row-ID key.
The task plan and design use the same contract. However, the normative scenario at
`specs/viewer-local-store-search/spec.md:89-93` still says that the next page continues by the exact
“activity/row-ID keyset.” That wording reintroduces a second mutable cursor component that the
requirement explicitly removed. It leaves both implementation and page-boundary tests with two
incompatible cursor contracts.

**Required artifact change:** Rewrite the scenario to require the exact immutable descending
recording-row-ID keyset within one unchanged frozen traversal. State that a relevant catalog change
invalidates the cursor and restarts from the first page rather than promising continuity across the
change.

### R2-2 — Medium — The filtered-export scenario contradicts the independent export-lease boundary

The revised architecture correctly says the query arbiter creates an immutable
`ViewerFilteredExportScope`, after which the export reader acquires its own finite export lease. It
also explicitly prohibits sharing or refreshing the interactive query lease concurrently. In
contrast, the normative Event Explorer scenario at
`specs/viewer-event-explorer-control/spec.md:106-110` says “the existing frozen query traversal
streams exactly that filtered result.” That makes the interactive traversal, rather than the
immutable scope plus export-owned traversal/lease, the export executor. This conflicts with the
local-store delta, design decision 3, task 2.3, and the A3 race remediation.

**Required artifact change:** Rewrite the scenario so the arbiter freezes the current query and
snapshot bounds into the immutable filtered-export scope and the dedicated export reader streams
that scope under its independent finite export lease. Preserve the existing atomic-destination and
cancellation guarantee.

## Additional Architecture/API Conclusions

- The schema-2 index descriptions use existing column names and retain rollback-safe, additive
  migration scope.
- Binding newly materialized `DeviceSessions.logicalID` to the admission connection ID is compatible
  with the current unique logical-ID seam and does not require rewriting closed historical rows.
- The fixed live ingress and projection bounds are expressed as deterministic accounting limits,
  while actual Swift heap and callback latency remain explicit evidence gates.
- Viewer-only placement, internal immutable Sendable facades, no new SDK/Core public API, and no
  third-party Core/SDK runtime dependency remain consistent with repository boundaries.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  — exit 0; `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` — exit 0 with no output after this report was written.

No production source, test source, or artifact other than this review report was modified by this
review.
