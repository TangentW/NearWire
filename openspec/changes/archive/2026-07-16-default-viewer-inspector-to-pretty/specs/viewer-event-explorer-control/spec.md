## MODIFIED Requirements

### Requirement: Event detail and renderer selection are bounded and fallback-safe

Selecting a retained Event SHALL resolve exact metadata and canonical content from the current memory snapshot. Raw JSON SHALL remain chunked, Pretty JSON SHALL retain its existing input/output/work bounds, and selection replacement or Clear/import/shutdown SHALL invalidate predecessor detail and renderer generations. Raw and Pretty content SHALL wrap within the available Inspector width and SHALL support explicit user selection, Copy, and Select All while remaining noneditable and non-draggable.

The immutable Viewer-internal Renderer registry SHALL remain available for Generic JSON, log line, key-value table, numeric-series, and timeline presentations. The Inspector SHALL label this presentation as Preview. Pattern selection and all existing input, time, derived-output, cancellation, accessibility, escaping, fallback, and redacted-reflection bounds SHALL remain enforced. A Generic JSON result SHALL show bounded Pretty content when available or bounded Raw content otherwise; it SHALL NOT present an empty instruction in place of the selected Event. Renderer preparation SHALL create no persistence or secondary Session authority.

The Inspector SHALL expose only Pretty, Raw, Preview, and Metadata tabs, ordered from leading to trailing in that sequence. A newly created Viewer analysis workspace SHALL select Pretty by default while preserving subsequent operator selection through the existing workspace state. It SHALL NOT expose a Tree or Causality tab, Tree expansion state, causality loading/error state, cross-Event candidate graph, or database row lookup. `correlationID` and `replyTo` MAY remain visible as metadata for the selected Event.

#### Scenario: Operator selects a renderer-compatible Event

- **WHEN** a retained `log.*`, `table.*`, `chart.*`, or `timeline.*` Event is selected
- **THEN** Preview prepares the bounded specialized presentation or safe Generic JSON fallback from the selected in-memory bytes
- **AND** no database or cross-Event query is performed

#### Scenario: Operator selects an ordinary JSON Event

- **WHEN** a retained Event has no specialized renderer pattern
- **THEN** Preview displays bounded formatted JSON or a bounded Raw fallback from the selected Event
- **AND** the operator is not redirected to a removed Tree view or shown an empty renderer state

#### Scenario: Operator copies inspected content

- **WHEN** the operator selects text in Raw or Pretty and invokes Copy
- **THEN** only the selected received text is written to the clipboard by that explicit action
- **AND** editing, paste, drag, automatic copy, and background disclosure remain unavailable

#### Scenario: Operator inspects causality metadata

- **WHEN** a selected Event contains correlation or reply identifiers
- **THEN** the identifiers remain available in Event metadata
- **AND** no Tree, Causality, or inferred cross-Event candidate list is shown

#### Scenario: Operator reads inspector choices

- **WHEN** Event detail is ready
- **THEN** Pretty is the leftmost inspector choice
- **AND** Metadata is the rightmost inspector choice
- **AND** Raw and Preview remain available between them

#### Scenario: Operator opens a new analysis workspace

- **WHEN** the Event Inspector is created for a new Viewer analysis workspace
- **THEN** Pretty is selected by default
- **AND** the operator may still select any other available inspector representation
