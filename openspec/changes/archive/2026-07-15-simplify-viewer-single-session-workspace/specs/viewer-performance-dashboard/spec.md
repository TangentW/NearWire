## MODIFIED Requirements

### Requirement: Performance projection is a rebuildable bounded view of raw Events

The Performance dashboard SHALL be a rebuildable projection of raw `nearwire.performance.snapshot` Events in the one current working Session. It SHALL never become a second persistence source, recording, or history owner. Clear and Session import SHALL advance the shared Store/presentation generation, cancel predecessor scans and chart preparation, clear stale buckets/tooltips/raw locators, and rebuild only from successor current-Session Events.

Each accepted snapshot SHALL retain the existing Core decoding, availability, finite-value, time-basis, bounded range, and aggregation semantics. Imported device aliases remain offline pseudonyms and SHALL NOT be treated as connected control targets.

#### Scenario: Current Session is cleared

- **WHEN** a Performance scan or chart delivery belongs to the pre-Clear generation
- **THEN** it cannot update the cleared dashboard
- **AND** later current-Session snapshots rebuild the projection normally

#### Scenario: A complete Session is imported

- **WHEN** import atomically installs valid raw Performance Events under a successor generation
- **THEN** the dashboard rebuilds from those raw Events using normal bounded projection
- **AND** no imported Device is presented as an active transport target
