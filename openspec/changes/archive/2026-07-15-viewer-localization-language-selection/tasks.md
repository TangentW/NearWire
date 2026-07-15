## 1. Planning Gate

- [x] 1.1 Audit Viewer-owned UI strings, presentation formatting, scene roots, settings/persistence seams, localization resources, tests, and unrelated local project changes.
- [x] 1.2 Complete proposal, design, capability deltas, and this task plan.
- [x] 1.3 Strictly validate the active OpenSpec change before source modification.

## 2. Language Authority and Resources

- [x] 2.1 Add a process-scoped System/English/Simplified Chinese preference with invalid-value fallback, persistence, and system-locale change publication.
- [x] 2.2 Add complete native English and Simplified Chinese Viewer resources with deterministic locale-aware lookup and formatting.
- [x] 2.3 Inject one effective locale into the main, Performance, and Settings scenes without restarting runtime or presentation state.
- [x] 2.4 Add the native Language Settings UI and accessible System behavior explanation.

## 3. Complete Viewer Localization

- [x] 3.1 Localize application/window actions, pairing, admission, Devices, details, settings, telemetry, validation, and failure guidance.
- [x] 3.2 Localize Timeline, search/filter, Inspector/renderers, composer, clear, import/export, dialogs, status, help, and accessibility text.
- [x] 3.3 Localize Performance selection, ranges, cards, charts, availability, state/gap guidance, raw reveal, formatting, and accessibility text.
- [x] 3.4 Preserve Event/App-provided values, protocol identifiers, Store data, Session JSON, logs, and locale-independent ordering verbatim.

## 4. Coverage, Documentation, and Evidence

- [x] 4.1 Add preference, lookup, formatting, resource parity/placeholder, source-boundary, and received-content preservation tests.
- [x] 4.2 Add bilingual SwiftUI behavior, settings, cross-window update, accessibility, and minimum/default layout coverage.
- [x] 4.3 Update Viewer documentation for supported languages, default behavior, manual selection, scope, and fallback.
- [x] 4.4 Run focused tests, full Viewer tests, strict-concurrency checks, Viewer and Demo builds, and save exact results under `evidence`.
- [x] 4.5 Launch and visually inspect the main, Performance, and Settings windows in both languages; save screenshots and observations.

## 5. Review and Completion

- [x] 5.1 Run independent architecture/API, correctness/testing, security/performance/documentation, and UI localization/aesthetics reviews.
- [x] 5.2 Fix every actionable finding and run fresh review rounds until every reviewer reports no unresolved finding.
- [x] 5.3 Complete the spec-to-evidence audit and strictly validate the finished change.
- [x] 5.4 Archive the change only after all implementation and evidence tasks are complete.
