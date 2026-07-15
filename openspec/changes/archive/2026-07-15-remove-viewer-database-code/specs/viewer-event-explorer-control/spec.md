## MODIFIED Requirements

### Requirement: Event detail and renderer selection are bounded and fallback-safe

Selecting a retained Event SHALL resolve exact metadata and canonical content from the current memory snapshot. Raw JSON SHALL remain chunked, Pretty JSON and tree derivation SHALL retain their existing input/output/work bounds, and selection replacement or Clear/import/shutdown SHALL invalidate predecessor detail and renderer generations.

The immutable Viewer-internal Renderer registry SHALL remain available for Generic JSON, log line, key-value table, numeric-series, and timeline presentations. Pattern selection and all existing input, time, derived-output, cancellation, accessibility, escaping, fallback, and redacted-reflection bounds SHALL remain enforced. Renderer preparation SHALL create no persistence or secondary Session authority.

The Inspector SHALL NOT expose a Causality tab, causality loading/error state, cross-Event candidate graph, or database row lookup. `correlationID` and `replyTo` MAY remain visible as metadata for the selected Event.

#### Scenario: Operator selects a renderer-compatible Event

- **WHEN** a retained `log.*`, `table.*`, `chart.*`, or `timeline.*` Event is selected
- **THEN** Renderer prepares the bounded specialized presentation or safe Generic JSON fallback from the selected in-memory bytes
- **AND** no database or cross-Event query is performed

#### Scenario: Operator inspects causality metadata

- **WHEN** a selected Event contains correlation or reply identifiers
- **THEN** the identifiers remain available in Event metadata
- **AND** no Causality tab or inferred cross-Event candidate list is shown

### Requirement: Current Session actions preserve one authoritative workspace

The workspace SHALL expose Clear and complete-Session JSON import/export against the same bounded memory Session. Clear SHALL atomically remove retained Event-derived data while preserving the listener, pairing code, connected Device lanes, negotiated policies, and composer capability. Export SHALL freeze only currently retained content after the unencrypted disclosure. Import SHALL be allowed only when no App is active or pending and SHALL atomically replace the inactive Session after bounded validation.

The Explorer SHALL NOT expose recording/device Store catalogs, Store row identities, traversal leases, durable pagination, recording mutation, retention, capacity, historical catalogs, filtered durable export, Store replacement, or database recovery state. Detailed transfer, Clear, and memory bounds are defined by `viewer-memory-session`.

#### Scenario: The operator clears an active Session

- **WHEN** Clear is confirmed while an App remains connected
- **THEN** Timeline, Inspector, diagnostics, and derived Performance content become empty
- **AND** successor Events may enter the same live Device connection without a Store lifecycle
