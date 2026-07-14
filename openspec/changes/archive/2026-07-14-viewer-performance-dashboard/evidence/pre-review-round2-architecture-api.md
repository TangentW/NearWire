# Pre-Implementation Architecture and API Review — Round 2

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Changes required before implementation.** A fresh review of the current artifacts confirms that
all four Round 1 architecture findings now have coherent behavioral contracts and proportionate
implementation/test tasks. One new module-ownership issue remains: the fixed 16-key metric vocabulary
has no reusable canonical owner visible to both SDK and Viewer.

Configured signing and inspection of entitlements embedded in a signed product remain explicitly
deferred by product-owner decision to Goal-level `release-hardening`. That deferred gate is not a
finding in this review.

## Fresh Scope Reviewed

- The current proposal, design, task list, remediation record, and all four capability deltas; no
  Round 1 conclusion was inherited.
- The existing Core V1 performance schema and SDK performance projection vocabulary.
- The Viewer package linkage, Event Explorer query arbiter, source identity, live projection, Store
  schema, and generation-bound Store gateway boundaries relevant to the proposed integration.
- Strict OpenSpec parsing/validation and whitespace validation for the active change.

## Round 1 Remediation Verification

| Prior concern | Round 2 result | Current evidence |
| --- | --- | --- |
| Aggregate content bytes and oversized no-copy handling | Resolved | The Store contract now reads type/length before content, emits metadata only above 65,536 bytes, caps copied content at 4,194,304 bytes, charges 512 bytes per carrier, and caps a page/live slice at 4,456,448 bytes (`design.md:48-66`; `specs/viewer-local-store-search/spec.md:5-25`; `specs/viewer-performance-dashboard/spec.md:3-17,89-95`; `tasks.md:8-11,37-39`). |
| Conservative schema-2 wall-gap mapping | Resolved | Schema 2 remains unchanged; monotonic sample order remains authoritative; wall-time gaps map only through unambiguous monotonic bucket envelopes, while regression, nonoverlap, ambiguity, or detail overflow suppress every inter-bucket connection (`design.md:135-147`; `specs/viewer-local-store-search/spec.md:27-34`; `specs/viewer-performance-dashboard/spec.md:126-147`; `tasks.md:18,40`). |
| Fixed 16-key GPU availability UI and tasks | Behavior resolved; ownership finding below remains | The design and dashboard spec now require a fixed availability section, explicitly show unavailable-only GPU/power/Celsius without numeric fabrication, and include UI/decode/integration tasks and tests (`design.md:149-157`; `specs/viewer-performance-dashboard/spec.md:83-87,137-141,214-220`; `tasks.md:15,30,38,42`). |
| One coordinator for traversal and reveal ordering | Resolved | One analysis-mode coordinator now owns the exact sequence: invalidate, cancel/join, release the departing traversal, switch mode when revealing, then submit successor/reveal work. Inactive cached presentation owns no lease (`design.md:173-186`; `specs/viewer-event-explorer-control/spec.md:3-21`; `specs/viewer-performance-dashboard/spec.md:188-212`; `tasks.md:25-26,41-42`). |

## Findings

### P2

1. **[P2] (confidence: 10/10) `proposal.md:46-50`, `design.md:98-103`, `tasks.md:15,30,38` — The fixed 16-key vocabulary has no canonical module owner that both producer and Viewer can use.**

   The artifacts call this the fixed “Core V1” inventory and require exact all-16-key behavior, but
   Core currently models 13 present fields and accepts an arbitrary string for unavailable metrics
   (`Core/Sources/NearWireCore/Builtins/Performance/PerformanceSnapshot.swift:12-188,198-227`). The
   exact 16-key vocabulary, including `device.gpuUtilization`, `device.powerWatts`, and
   `device.temperatureCelsius`, exists only as the SDK-internal `PerformanceMetricKey`
   (`SDK/Sources/NearWirePerformance/Internal/PerformanceSnapshotProjection.swift:8-25`). Viewer
   links only `NearWireCore` (`Viewer/NearWireViewer.xcodeproj/project.pbxproj:188,266`) and therefore
   cannot reuse that definition. Implementing the current tasks requires either an undocumented
   Viewer copy that can drift from the producer or a Core/SDK change that contradicts the proposal's
   Viewer-only production impact statement. The former also conflicts with the repository rule that
   shared platform-neutral implementation belongs in Core.

   **Required artifact fix:** Make the exact metric-key inventory an internal Core SPI (for example,
   a `PerformanceMetricKey` or `PerformanceSnapshotSchema` inventory), update the SDK projection and
   Viewer to reuse it, and revise the proposal/tasks to permit the necessary internal Core and SDK
   source/test changes. This does not require a public SDK or wire-format change. If intentional
   duplication is chosen instead, the design must name that exception, enumerate all exact strings,
   and require a parity test against the producer vocabulary.

## Confirmed Architecture and API Boundaries

- Raw durable Events plus the existing bounded live projection remain the only authoritative data;
  no derived persistence, second Store, second session manager, or second live projection is added.
- Performance remains one exact current or historical device session, while the existing shared
  source/device selection and merged Event timeline remain authoritative.
- The specialized Store traversal can remain generation-bound and use the existing exact-device
  monotonic index without a schema migration; wall-only gaps have a conservative no-guess fallback.
- Raw reveal passes only source generation and a metric-specific journal key, then uses the existing
  Explorer's exact durable-or-live resolution after ordered traversal handoff.
- macOS 13, Swift 5 language mode, the system Charts framework, and no new third-party/root-package
  dependency remain compatible with the proposed Viewer implementation.

## Validation

- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive` — passed.
- `env DO_NOT_TRACK=1 openspec show viewer-performance-dashboard --json --deltas-only` — parsed ten deltas.
- `git diff --check -- openspec/changes/viewer-performance-dashboard` — passed before this report.
- Implementation tests were not run because this is an artifact-only pre-implementation review.

**Unresolved findings: 1**
