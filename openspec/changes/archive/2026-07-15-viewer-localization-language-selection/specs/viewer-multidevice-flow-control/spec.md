## ADDED Requirements

### Requirement: Device and connection controls are complete in both supported languages

Pairing, listener, admission, approval, Devices, Device details, settings, telemetry, disconnect state, retry/reset, and fixed validation guidance SHALL be available in English and Simplified Chinese with localized help and accessibility text. A locale change SHALL NOT regenerate a pairing code, change approval policy, reconnect a Device, alter rate settings, retarget Event or Performance scope, or mutate Device continuity state.

App display name, application identifier/version, Bundle ID, nickname, installation alias, pairing code, UUID, and safe identity hints SHALL remain verbatim. Viewer-owned labels that describe those values as unauthenticated SHALL be localized without weakening the warning.

#### Scenario: Language changes during an active connection

- **WHEN** one or more Apps are connected and the operator selects another Viewer language
- **THEN** Device controls, states, telemetry labels, and safety guidance update immediately
- **AND** every session route, rate limit, Device identity value, and active connection remains unchanged
