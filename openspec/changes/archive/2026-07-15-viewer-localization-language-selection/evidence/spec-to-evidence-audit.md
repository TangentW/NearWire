# Spec-to-Evidence Audit

## Viewer application foundation

- Complete English and Simplified Chinese resources: `Localizable.xcstrings`; resource parity, nonempty values, placeholders, representative keys, and source boundaries pass in `ViewerLocalizationTests`.
- System and manual language authority: `ViewerLanguageController`; tests cover default System, persistence, malformed string/type canonicalization, system notification publication, and every Chinese locale resolving to exact `zh-Hans`.
- Immediate shared-scene application: one controller is injected into main, Performance, and Settings scene roots. Visual QA observed already-open main and Performance windows switch together without runtime restart.
- Viewer-only boundary and verbatim received content: the change does not modify Core, SDK, NearWireUI, Demo source, protocol, Store, or export schemas. Tests verify unknown application content is not treated as a localization key; source review found no new persistence or logging sink.

## Viewer Event explorer and control

- Timeline, filters, Inspector, renderer, composer, import/export, status, help, accessibility, and AppKit save-panel text are catalog-backed.
- English and Simplified Chinese filter/composer compact-layout tests pass.
- Event types, content, JSON, user drafts, and exported values remain data rather than localization keys; the full Viewer regression suite passes.

## Viewer multi-device flow control

- Pairing, listener, admission, Devices, details, settings, state, validation, and safety text are localized.
- App names, identifiers, pairing codes, UUIDs, and received identity values remain verbatim.
- Language selection mutates only presentation preference and locale; no listener, admission, Session, Store, rate, or connection path is restarted.

## Viewer Performance dashboard

- The singleton Performance window receives the shared locale and localizes selection, ranges, cards, charts, availability, guidance, formatting, tooltips, and accessibility summaries.
- Visual QA confirmed manual English and System Simplified Chinese switching in an already-open Performance window.
- Performance computation, selection, Store queries, projection state, metric keys, wire values, cleanup, and privacy boundaries are unchanged; the full Viewer suite and Release build pass.

## Final gates

- Focused localization/layout tests: PASS.
- Full Viewer tests: `465` executed, `2` skipped, `0` failures.
- Root Swift package tests: `546` executed, `0` failures.
- Viewer Release and Demo simulator builds: PASS.
- Independent review round 2: CLEAN in architecture/API, correctness/testing, security/performance/documentation, and UI localization/aesthetics.
- `openspec validate viewer-localization-language-selection --strict`: PASS.
- `git diff --check`: PASS.
