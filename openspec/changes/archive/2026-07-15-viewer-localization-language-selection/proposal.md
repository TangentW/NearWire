## Why

The macOS Viewer currently exposes English-only controls, guidance, errors, accessibility text, and performance presentation. This makes the internal tool unnecessarily difficult for Simplified Chinese operators and gives the application no explicit language choice when a user's preferred Viewer language differs from the macOS language.

A partial translation would be misleading: the main Event workspace, Device controls, composer, dialogs, import/export flow, and auxiliary Performance window form one product surface and must switch together.

## What Changes

- Localize the complete macOS Viewer user interface in English and Simplified Chinese, including visible labels, guidance, dialogs, errors, menus, formatting, tooltips, and accessibility text.
- Follow the current macOS language by default and react to relevant system-locale changes.
- Add a native Viewer Settings scene with a persistent language choice: System, English, or Simplified Chinese.
- Apply a manual language change immediately and consistently to the main Event window, singleton Performance window, Settings window, and later-presented sheets without restarting the Viewer or its runtime.
- Keep protocol values, Event payloads, user/App-provided text, exported JSON, logs, persistence schema, SDK APIs, and the Demo unchanged.
- Add resource-completeness, preference, formatting, UI, accessibility, build, and regression coverage.

## Capabilities

### Modified Capabilities

- `viewer-application-foundation`: the Viewer owns one process-scoped language preference, follows the system by default, exposes a native Settings choice, and applies one locale consistently across both supported windows.
- `viewer-event-explorer-control`: the current-Session Event workspace, filters, Inspector, composer, import/export flow, and fixed guidance are available in English and Simplified Chinese without translating Event content or wire values.
- `viewer-multidevice-flow-control`: pairing, admission, Device rows, details, settings, telemetry, and fixed validation guidance are localized while App-provided identity values remain verbatim.
- `viewer-performance-dashboard`: the dedicated Performance window localizes controls, cards, charts, availability, states, guidance, number/date formatting, and accessibility descriptions while metric identifiers and received values retain their protocol meaning.

## Impact

The change affects Viewer SwiftUI scene composition, a small Viewer-only language-preference model, Viewer localization resources, locale-aware presentation formatting, Viewer tests, the manually maintained Viewer Xcode project, and Viewer documentation. It does not change Core, SDK, NearWireUI, Demo, transport, Bonjour, TLS, wire schemas, Event limits, Session JSON, Store schema, entitlements, or dependencies.
