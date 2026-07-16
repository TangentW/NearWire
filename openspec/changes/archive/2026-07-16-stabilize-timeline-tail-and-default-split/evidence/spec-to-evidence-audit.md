# Spec-to-evidence audit

## Timeline tail requirements

- Production: `ViewerExplorerTimelineView` has no synthetic tail row or private tail identity.
- Production: `ScrollViewProxy` targets the final `ViewerExplorerEventIdentity`.
- Production: the macOS 13/14 frame preference and disappearance fallback are attached only to the
  final real Event row.
- Tests: the hosted Timeline asserts one native table row per Event, verifies that the appended
  real row becomes visible while following, and verifies stable position after manual scrolling.
- State tests: following, manual reading, and Jump to Latest behavior remain covered.

## Workspace split requirements

- Production: initial two-panel layout temporarily constrains Inspector to 30% while Timeline takes
  the remaining 70%, then releases the bound for native divider resizing.
- Production: existing minimum widths remain in force and single-panel layouts have no peer bound.
- Tests: offscreen renders assert the approximate 70/30 ratio at minimum, standard, and wide sizes
  in light and dark appearances.
- Tests: Timeline-only and Inspector-only layouts each fill the available workspace.
- Documentation: `Documentation/Viewer-Event-Explorer.md` describes the initial ratio, adjustable
  divider, and single-panel expansion.

## Quality gates

- Viewer build passed.
- ViewerFoundationTests passed with 98 passed, 0 failed, and 1 skipped.
- Strict OpenSpec validation passed.
- Diff check passed.
- Rendered screenshots were inspected.
- Three independent review axes completed a clean post-fix round with no findings.

All modified requirements and scenarios have corresponding production behavior and validation
evidence. No unrelated SDK, transport, storage, or public API behavior changed.
