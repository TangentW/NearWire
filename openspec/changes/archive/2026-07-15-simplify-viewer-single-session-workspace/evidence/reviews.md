# Independent Review Record

Independent reviewers covered architecture/API, correctness/testing, security/performance/documentation, and UI aesthetics/interaction. Every actionable finding was fixed and submitted to a fresh reviewer round.

## Early implementation rounds

- Clear admission originally rejected connected Devices, and deferred admission decisions could cross the workspace-mutation boundary. The policy now permits connected Clear, keeps import inactive-only, and quiesces each admitted predecessor before mutation.
- Termination could wait indefinitely, workspace removal did not retry safely, and import cancellation did not interrupt every bulk or second-pass path. Cleanup now has a bounded application wait with finite retained retries, while import and SQLite progress paths are cancellation-aware.
- Transfer counts, file limits, and incremental export byte budgeting were inconsistent. Import/export now share explicit bounds, reject over-budget output before destination replacement, preserve the destination on failure, and distinguish capacity failures from malformed input.
- Per-write retained-row counting was quadratic, and an ingress work-limit rejection could leave the queue unable to drain. Schema-version-3 retained counters and triggers make quota checks constant-time, while rejected work drains and leaves Clear reusable.
- Export disclosure and guidance omitted App metadata and could misstate complete export options. Disclosure now names Session metadata, notes, annotations, diagnostic gaps, Event metadata/content, and peer-provided App identity fields, while fixed guidance accurately distinguishes complete and filtered exports.

## Compatibility and identity rounds

- Valid schema-version-2 Stores lacked the new counters. The transactional version-2 to version-3 migration installs and initializes them from authoritative rows; version-1 migration and fresh creation converge on the same schema.
- Imported or reopened coordinator-generated diagnostic Gaps could reuse a sequence. The coordinator now resumes from the durable maximum and exact tests cover both import and same-process reopen.
- Import capacity failures used generic corrupt-input guidance. They now use a dedicated safe fixed message.
- Human-readable disclosure warning copy was compared as a protocol field, rejecting earlier schema-version-1 exports. Import now validates only stable disclosure fields, and a complete legacy-warning export fixture round-trips successfully.

## UI and interaction rounds

- Device and pending-approval overflow lacked visible horizontal affordance; Clear accessibility wording was too weak; and legacy Source terminology remained reachable. Scroll indicators, destructive accessibility help, and current-Session terminology now cover those paths.
- Minimum-size layout initially let the Timeline toolbar cross the Analysis divider when Composer was visible. Analysis now retains a 260-point minimum and higher split priority; Composer uses a bounded 180-to-360-point scrollable viewport with 240-point content; pane drawing is clipped to its split region.
- The six-variant render test originally checked only bitmap dimensions. It now resolves layout probes and verifies Analysis height, Timeline containment within Analysis, Composer bounds and host containment, and no Analysis-to-Composer or Timeline-to-Composer intersection at minimum, standard, and wide sizes in light and dark appearances.
- A final signed application launch confirmed the post-fix hierarchy, panel controls, standard dark layout, Composer scrolling, and refreshed live screenshot.

## Evidence review rounds

- Reviewers rejected stale full-suite evidence after late schema, Gap-sequence, disclosure, and layout fixes. Validation was rerun after each production change and the final evidence now points to the current 437-test Viewer result bundle.
- One spec-audit test name and one geometry description were inaccurate. Both were corrected to exact source identifiers and actual containment/intersection semantics.

## Final round

- Architecture/API: CLEAN.
- Correctness/testing/evidence: CLEAN.
- Security/performance/documentation: CLEAN.
- UI aesthetics/interaction: CLEAN.

There are no unresolved findings.
