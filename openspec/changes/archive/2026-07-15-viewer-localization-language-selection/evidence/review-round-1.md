# Independent Review Round 1

## Architecture and API

Finding: System mode exposed the raw macOS locale to SwiftUI while programmatic lookup normalized it. A Traditional Chinese locale could therefore mix English SwiftUI literals with Simplified Chinese programmatic strings.

Resolution: `ViewerLanguageController.effectiveLocale` now exposes exactly `zh-Hans` for every Chinese system locale and exactly `en` otherwise. Regression tests cover `zh-Hant-TW`, `zh-HK`, and `zh-Hans-HK`.

## Correctness and testing

Findings:

- The export `NSSavePanel` title and message were assigned fixed English strings.
- Resource parity alone could not detect a fixed AppKit string that bypassed localization.
- System-notification and Simplified Chinese compact-layout coverage were incomplete.

Resolutions:

- The save panel now uses the effective Viewer locale.
- A unit-level source-boundary check covers fixed localization calls and AppKit panel assignments without adding a repository script.
- Shared-scene notification deduplication and English/Simplified Chinese compact filter/composer layouts are covered.

## Security, performance, and documentation

Findings:

- Malformed UserDefaults content remained stored after falling back to System.
- Programmatic lookup repeatedly rebuilt localized bundles on hot UI paths.
- Multiple scene observers could republish the same normalized locale change.
- Evidence and explicit bilingual layout coverage were not yet complete.

Resolutions:

- Invalid stored content is replaced by the canonical `system` raw value.
- Main English and Simplified Chinese bundles are cached once.
- Locale refresh compares the normalized supported locale and publishes once.
- Tests, visual evidence, documentation, and validation evidence were completed.

## UI localization and aesthetics

The first visual pass found no clipping or terminology issue in the inspected main, Performance, and Settings surfaces. Its stale-binary concern about Traditional Chinese was superseded by the architecture fix and rechecked in round 2.
