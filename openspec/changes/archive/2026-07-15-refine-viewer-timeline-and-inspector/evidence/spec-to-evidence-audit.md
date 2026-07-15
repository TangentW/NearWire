# Spec-to-Evidence Audit

## Timeline Requirement

- The production row shows Event type, exceptional state, and receive time on one header line, followed by a summary limited to three lines.
- Device/source, direction, priority, byte count, and normal acceptance state remain absent from Timeline rows and available in Inspector metadata.
- The 340-point fitting regression proves that exceptional badges collapse to a compact status count instead of adding a line.
- The viewport-state regression covers mounted tail detection, manual reading, return to tail, stale geometry rejection, explicit Jump to Latest, and stable row identity.
- Evidence: `implementation-validation.md`, `render-validation.md`, and `review-round-3.md`.

## Inspector Requirement

- The Inspector exposes only Metadata, Raw, Pretty, and Preview.
- Tree state and UI are removed while the shared bounded JSON scanner remains available to specialized renderers.
- Raw and Pretty use read-only, wrapping, selectable native text with explicit Copy and Select All; edit, paste, drag, and automatic clipboard paths remain unavailable.
- Generic Preview shows bounded Pretty content or the first bounded Raw chunk, while specialized renderer behavior remains covered.
- Evidence: `implementation-validation.md`, `review-round-1.md`, `review-round-2.md`, and `review-round-3.md`.

## Quality Gates

- Final focused tests: 6 passed, 0 failures.
- Final Viewer suite: 169 tests executed, 1 existing opt-in test skipped, 0 failures.
- Entitlement packaging probe: 1 passed, 0 failures.
- Localization source-boundary assertions: reproduced outside the macOS test host after the host exited unexpectedly; all missing-key and AppKit-panel result sets were empty.
- Viewer Debug build: succeeded with Swift 5 language mode and strict-concurrency checking enabled.
- `git diff --check`: passed.
- Strict active-change validation: passed; the only emitted error was the non-gating PostHog DNS flush failure after validation completed.
- Three independent final reviewers: no findings.

Every requirement and scenario has implementation, focused regression, full-suite/build, visual, and independent-review evidence. No unresolved finding remains.
