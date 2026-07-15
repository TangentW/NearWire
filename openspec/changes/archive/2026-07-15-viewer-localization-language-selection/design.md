## Context

Viewer UI strings currently originate from three places: direct SwiftUI literals, fixed presentation strings produced by Viewer models/controllers, and formatted accessibility or status strings. SwiftUI can localize literal keys through the scene locale, but plain `String` values and Foundation formatters do not automatically follow a SwiftUI locale override. NearWire also has two independent windows and several sheets, so changing only the main root environment would create mixed-language UI.

The repository has no existing Viewer localization resources or Settings scene. The Viewer project is manually maintained and currently carries local uncommitted Xcode formatting/signing changes that must remain outside this change.

## Goals and Non-Goals

Goals:

- Provide complete English and Simplified Chinese coverage for Viewer-owned UI.
- Follow macOS language by default and allow a persistent manual override.
- Apply language changes immediately to all Viewer scenes without restarting networking, Session state, or presentation work.
- Keep Event content, App identity values, protocol tokens, export data, and diagnostics semantically unchanged.
- Use native Apple localization and formatting APIs with no new dependency.
- Make missing translations and accidental unlocalized fixed UI detectable in tests.

Non-goals:

- Localize the iOS SDK, NearWireUI, Demo, protocol, Event payloads, JSON exports, logs, or developer-facing diagnostics.
- Add languages other than English and Simplified Chinese.
- Translate arbitrary Event types, Event content, App names, Bundle IDs, nicknames, pairing codes, or wire enum raw values.
- Persist locale-derived content or add a localization service to Core.
- Restart or reconnect the Viewer runtime when language changes.

## Decisions

### One process-scoped language controller owns the preference

`ViewerLanguageController` is a MainActor `ObservableObject` created once by `NearWireViewerApp`. It stores only one bounded enum raw value under a Viewer-specific `UserDefaults` key. Unknown or malformed stored values fall back to System. The enum exposes System, English, and Simplified Chinese choices and resolves them to an effective locale.

System mode observes the platform locale-change notification so open scenes republish when relevant macOS preferences change. Any Chinese preferred locale, including Traditional Chinese locales, deliberately resolves to the supported Simplified Chinese presentation; every non-Chinese locale resolves to English. English and Simplified Chinese manual choices use explicit stable locale identifiers. Preference mutation publishes once and persists immediately; it does not touch application runtime, Store, Session, Event presentation, window identity, or networking.

### Every Viewer scene receives the same locale

The main Window, singleton Performance Window, and Settings scene receive the controller and its effective locale at their roots. Sheets, alerts, menus, and child views inherit that environment. A manual change therefore updates both existing windows and later presentation surfaces in one process turn without recreating the application model.

The Settings scene uses a native Form and Picker with an explicit Language label and concise explanation of System behavior. The three choices remain understandable in either active language; English and Simplified Chinese use self-identifying names. The setting is content-free and persists across launches.

### Native resources use English development values and Simplified Chinese translations

Viewer owns one localized resource table with English as the development language and a complete `zh-Hans` translation. Direct SwiftUI literals remain localization keys when safe. Fixed runtime strings, interpolated messages, accessibility labels, and programmatic formatting use a Viewer-only localization helper with the effective locale.

The helper performs deterministic bundle lookup for the supported locale and falls back to the English development value if a resource is unavailable. It supports locale-aware format arguments without accepting Event content as a localization key. Number, percentage, byte-count, date, duration, and list presentation use the effective locale where they are user-visible; protocol ordering and persistence continue using locale-independent representations.

### Product text and received text have an explicit boundary

Viewer-owned labels, state descriptions, validation guidance, errors, confirmation text, empty states, chart descriptions, and accessibility sentences are localized. App-provided display names, Bundle IDs, nicknames, Event types, Event content, JSON keys/values, pairing codes, UUIDs, wire directions, raw priorities, and exported Session data are displayed verbatim unless a separate localized Viewer label surrounds them.

Internal log messages, test diagnostics, Store reasons, protocol enum raw values, and stable persistence keys remain English and are not localization resources. Localized strings are never written into the Store or exported JSON.

### Resource and source coverage are enforced

Tests load both localizations and verify identical key coverage, nonempty translations, required format placeholders, and representative strings from every Viewer surface. Preference tests cover default System, persistence, invalid-value fallback, explicit locale resolution, and system-change publication. Presentation tests cover immediate shared-scene locale updates, locale-aware formatting, user-content preservation, accessibility labels, and layouts at supported minimum/default sizes with longer Simplified Chinese text.

A source-boundary test maintains an allowlist for intentional verbatim/product-independent literals and rejects newly introduced unlocalized Viewer UI literals or fixed presentation strings. The check stays inside the Viewer test target rather than adding repository validation scripts.

## Risks and Mitigations

- A plain `String` passed to SwiftUI could bypass environment localization. Programmatic fixed text uses explicit localized lookup and representative UI tests exercise both locales.
- The two windows could diverge after a manual change. Both receive the same process controller, and cross-window tests assert the same preference revision and effective locale.
- Simplified Chinese text could clip compact controls. Layout/rendering coverage checks the minimum supported main and Performance window sizes, filters, dialogs, and Settings in both appearances.
- Locale-aware formatting could change protocol behavior. Formatting is limited to presentation; query ordering, keys, persistence, JSON, and wire values retain locale-independent code paths.
- A translation key could expose or transform received content. The product/received boundary keeps arbitrary values verbatim and tests representative Event and Device content.
- Editing the Viewer project could include unrelated local Xcode changes. The localization resource membership is staged as an isolated project-file hunk and existing user changes remain unstaged.

## Verification

- Focused language-controller, lookup, formatting, resource-completeness, and source-boundary unit tests.
- Viewer UI/presentation tests in English and Simplified Chinese for main, Performance, Settings, filters, dialogs, and accessibility behavior.
- Full Viewer test suite, strict-concurrency checks, unsigned and signed Viewer builds where the local environment permits, Demo regression build, and strict OpenSpec validation.
- Launched visual inspection of both Viewer windows and Settings in both languages, including immediate switching and minimum-size layouts.
- Independent architecture/API, correctness/testing, security/performance/documentation, and UI localization/aesthetics reviews repeated after fixes until no actionable finding remains.
