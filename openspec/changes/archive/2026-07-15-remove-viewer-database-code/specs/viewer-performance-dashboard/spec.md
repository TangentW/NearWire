## MODIFIED Requirements

### Requirement: Performance projection is a bounded view of current memory Events

The Performance dashboard SHALL select one exact current-Session connection and freeze its bounded memory Event slice before projection. Target identity, cache identity, range bounds, gaps, raw Event locators, cancellation, and successor publication SHALL use runtime, connection, and journal identities only. They SHALL contain no recording row, persistent upper bound, traversal lease, or persistence fallback.

The projection SHALL validate only `nearwire.performance.snapshot` content and SHALL preserve typed availability rather than invent values. Runtime replacement, Device replacement, import, Clear, or window close SHALL invalidate and join predecessor work before a successor owns publication.

#### Scenario: Performance refreshes from current Session

- **WHEN** retained performance Events change for the selected connection
- **THEN** one frozen memory slice produces the successor cards and charts
- **AND** no database query or historical reconciliation is constructed

### Requirement: Raw Event reveal resolves only exact retained identity

Open Raw Event SHALL resolve the selected metric's representative journal key against the current memory Session at action time. Success SHALL focus the main Viewer, make Inspector visible, and select the exact retained Event. Evicted, stale, or unavailable identity SHALL preserve prior selection and Performance presentation with fixed guidance. Viewer SHALL NOT choose a neighboring Event, copy raw JSON through the Performance model, or use a persistence fallback.

#### Scenario: Raw contributing Event was evicted

- **WHEN** Open Raw Event resolves a journal key no longer retained in memory
- **THEN** the prior Event selection and Performance presentation remain unchanged with fixed guidance
- **AND** no database fallback or nearby Event is selected
