## 1. Planning Gate

- [x] 1.1 Complete proposal, design, capability delta, and this task plan.
- [x] 1.2 Strictly validate the active OpenSpec change before source modification.

## 2. Timeline Refinement

- [x] 2.1 Remove Device/source, direction, priority, and byte count from Timeline rows and align accessibility output.
- [x] 2.2 Observe the real Timeline scroll viewport and implement bottom-owned automatic tail following plus Jump to Latest.
- [x] 2.3 Add focused tests for row presentation and at-bottom, scrolled-away, return-to-bottom, and explicit jump decisions.

## 3. Inspector Refinement

- [x] 3.1 Remove Tree UI, controller/preparation state, expansion code, and Tree-only tests while retaining shared JSON scanning.
- [x] 3.2 Make Raw and Pretty text wrap, select, Copy, and Select All while rejecting edits, paste, drag, and automatic clipboard writes.
- [x] 3.3 Present Renderer as Preview and show useful bounded Pretty or Raw content for Generic JSON while preserving specialized renderer behavior.
- [x] 3.4 Update English and Simplified Chinese localization for changed labels, guidance, accessibility copy, and menus.

## 4. Validation and Evidence

- [x] 4.1 Run focused tests, full Viewer tests, strict-concurrency checks, and the Viewer build; save exact results under `evidence`.
- [x] 4.2 Launch or render the Event workspace and record a focused visual/interaction inspection.

## 5. Review and Completion

- [x] 5.1 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews focused on actionable regressions.
- [x] 5.2 Fix every actionable finding and run a fresh clean review round without unrelated scope expansion.
- [x] 5.3 Complete the spec-to-evidence audit, strictly validate the finished change, and archive it.
