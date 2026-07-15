## ADDED Requirements

### Requirement: Viewer follows the system language and supports one manual language preference

The Viewer SHALL provide complete English and Simplified Chinese localization for Viewer-owned UI. A fresh or invalid preference SHALL use System and resolve from the current macOS language. Viewer Settings SHALL offer exactly System, English, and Simplified Chinese. A manual choice SHALL persist as one bounded enum value across launches and apply immediately to the main Event window, singleton Performance window, Settings, and inherited presentation surfaces without restarting the runtime, listener, working Session, Store, or window identity.

System mode SHALL react to relevant macOS locale-change publication. Any Chinese system locale, including Traditional Chinese locales, SHALL resolve to the supported Simplified Chinese presentation; every non-Chinese system locale SHALL resolve to English. English and Simplified Chinese manual choices SHALL use explicit supported locales. Missing or malformed preference data SHALL safely fall back to System; a missing translation SHALL fall back to the English development value. The preference SHALL contain no Event, Device, identity, or Session content.

#### Scenario: Viewer starts without a language preference

- **WHEN** the Viewer launches with no valid stored language value and macOS resolves to Simplified Chinese
- **THEN** all Viewer-owned UI in both supported windows is presented in Simplified Chinese
- **AND** runtime and Session startup are identical to an English launch

#### Scenario: macOS uses Traditional Chinese

- **WHEN** Viewer uses System and the current macOS preferred language is a Traditional Chinese locale
- **THEN** every Viewer-owned surface uses the supported Simplified Chinese localization
- **AND** Settings continues to show System as the selected preference

#### Scenario: Operator selects English while both windows are open

- **WHEN** the main Event window and Performance window currently use Simplified Chinese and the operator selects English in Settings
- **THEN** both windows and later-presented sheets switch to English without process or runtime restart
- **AND** Event selection, filters, Device scope, chart scope, Session state, and active connections remain unchanged

#### Scenario: Stored preference is malformed

- **WHEN** the stored language raw value is unknown or malformed
- **THEN** Viewer uses System and exposes System as the selected Settings choice
- **AND** it neither crashes nor invents a fourth language state

### Requirement: Viewer localization stays inside the Viewer product boundary

Viewer SHALL localize its own labels, guidance, validation, errors, confirmations, menus, tooltips, state descriptions, formatted presentation, and accessibility text. It SHALL display App-provided names, Bundle IDs, nicknames, pairing codes, Event types, Event content, JSON keys/values, UUIDs, and other received values verbatim. Localization SHALL NOT mutate protocol values, wire behavior, query ordering, Store schema/content, Session JSON, exports, logs, SDK APIs, NearWireUI, or Demo UI.

#### Scenario: Received content resembles a localization key

- **WHEN** an App sends an Event type or content string identical to Viewer product text
- **THEN** Timeline and Inspector display the received value byte-for-byte as decoded
- **AND** only surrounding Viewer-owned labels follow the selected language
