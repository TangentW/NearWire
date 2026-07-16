## 1. Planning

- [x] 1.1 Complete proposal, design, capability delta, and tasks.
- [x] 1.2 Strictly validate the change before source modification.

## 2. Stable split

- [x] 2.1 Replace the temporary `HSplitView` constraint with a stable native divider position.
- [x] 2.2 Preserve native resizing, minimum widths, panel visibility, and single-panel expansion.
- [x] 2.3 Remove the delayed constraint-release state and related timing behavior.

## 3. Validation

- [x] 3.1 Add delayed-settle, content-update, divider-resize, and single-panel regressions.
- [x] 3.2 Run focused and class-level tests, Viewer build, screenshot inspection, and strict validation.
- [x] 3.3 Run independent review rounds, fix findings, audit evidence, and archive the change.
