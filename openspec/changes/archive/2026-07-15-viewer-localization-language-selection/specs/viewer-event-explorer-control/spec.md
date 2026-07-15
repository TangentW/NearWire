## ADDED Requirements

### Requirement: Current-Session Event surfaces are complete in both supported languages

The main Event window SHALL provide English and Simplified Chinese versions of Viewer-owned Timeline, search, filter, Inspector, renderer, composer, Clear, import, export, disclosure, empty, loading, error, help, and accessibility text. A locale change SHALL preserve the current Event traversal, scope, filter values, selected Event, Inspector tab, panel visibility, composer draft, pause state, export authority, and working Session while republishing only presentation text and locale-aware formatting.

Event types, content, JSON fields/values, renderer payloads, user-entered drafts, and exported values SHALL remain verbatim. Protocol directions and priorities MAY receive localized display labels but SHALL retain their stable raw values in queries, Store rows, and exports.

#### Scenario: Language changes with one Event selected

- **WHEN** Timeline has a filtered selection and Inspector detail and the operator changes the Viewer language
- **THEN** fixed controls, status, formatting, and accessibility text update immediately
- **AND** the exact filter, selected Event identity, raw content, Inspector tab, and traversal remain unchanged

#### Scenario: Event content contains English product words

- **WHEN** received JSON contains keys or values such as `Clear`, `System`, or `Performance`
- **THEN** the raw and structured Inspector views preserve those values verbatim in either Viewer language
- **AND** Viewer-owned surrounding controls are localized normally
